引入 Role-Based Access Control (RBAC) 后，系统的复杂度主要体现在 入口网关 (Ingress/API Gateway) 的鉴权逻辑以及 审计 (Audit) 上。后端的 Stream Process (Kafka -> Airflow) 本身不需要改动太多，因为它应该只接收“由于合法指令而产生”的消息。
这里是针对 Admin vs. User (Regular) 的设计方案：
1. 用户模型与认证 API 设计 (Identity & Access Management)
你需要区分“谁在操作”以及“由于什么权限”。
A. 数据库模型 (User & Role)
不要把 Admin 和 User 分成两张表，用 roles 字段区分。
CREATE TABLE users (
    user_id VARCHAR(64) PRIMARY KEY,
    email VARCHAR(255) UNIQUE NOT NULL,
    password_hash VARCHAR(255) NOT NULL,
    role VARCHAR(20) NOT NULL, -- 'ROLE_USER', 'ROLE_ADMIN'
    tenant_id VARCHAR(64),     -- Admin 可能属于 'system-tenant'
    is_active BOOLEAN DEFAULT TRUE,
    created_at TIMESTAMP
);

B. Registration API (注册)
这两种角色的注册流程完全不同：
 * 普通用户 (Public API):
   * POST /api/v1/auth/register
   * 逻辑: 任何人都可以调用。系统默认分配 ROLE_USER。
   * Payload: { "email": "...", "password": "..." }
 * 管理员 (Internal/Protected API):
   * 严禁开放注册！ 你不希望任何人随便调一个 API 就变成了 Admin。
   * 方法 1 (Seed): 系统初始化时通过 SQL 脚本插入第一个 Super Admin。
   * 方法 2 (Invite-Only): 只有现有的 Admin 可以创建新的 Admin。
     * POST /api/v1/admin/users (Header: Authorization: Bearer <Admin_Token>)
     * Payload: { "email": "new_admin@company.com", "role": "ROLE_ADMIN" }
C. Authentication (登录 & Token)
登录接口是统一的：POST /api/v1/auth/login。
关键在于 JWT Token 的设计。Token 必须包含权限声明 (Claims)，这样后续的服务（包括删除服务）不需要查库就能知道他是谁。
JWT Payload 示例:
{
  "sub": "user_888",         // User ID
  "iss": "auth-service",
  "iat": 1700000000,
  "exp": 1700003600,
  "scope": "role:admin",     // <--- 关键：或者是 ["ROLE_ADMIN", "WRITE_access"]
  "tenant_id": "tenant_123"  // <--- 关键：Context
}

2. 删除操作的设计变更 (Impact on Deletion Flow)
引入 Admin 后，删除操作有了两种场景：
 * Self-Service: 用户自己删自己（常规）。
 * Admin Action: 管理员删用户/租户（因为违规、欠费、或手动 GDPR 请求）。
这对你的 Ingress API 和 Kafka Message 都有影响。
A. Ingress API 层 (Spring Security 控制)
你的 Controller 需要能够处理这两种权限。
@RestController
@RequestMapping("/api/v1")
public class DeletionController {

    // 场景 1: 用户删自己的服务
    @DeleteMapping("/services/{serviceInstanceId}")
    @PreAuthorize("hasRole('USER')") // 只有普通用户
    public ResponseEntity<Void> deleteMyService(
            @PathVariable String serviceInstanceId,
            @AuthenticationPrincipal Jwt jwt) { // 从 Token 拿当前用户信息
        
        String currentUserId = jwt.getSubject();
        String currentTenantId = jwt.getClaim("tenant_id");
        
        // 【关键校验】: 必须确保要删的资源属于当前用户！
        // 防止 User A 拿着自己的 Token 去调 API 删 User B 的资源 (IDOR 漏洞)
        resourceOwnerCheckService.verifyOwner(serviceInstanceId, currentUserId);

        // 发送 Kafka 消息
        deletionProducer.sendDeletionRequest(currentTenantId, serviceInstanceId, "SELF_REQUEST");
        return ResponseEntity.accepted().build();
    }

    // 场景 2: Admin 强制删除任何人的服务
    @DeleteMapping("/admin/services/{serviceInstanceId}")
    @PreAuthorize("hasRole('ADMIN')") // 只有管理员
    public ResponseEntity<Void> forceDeleteService(
            @PathVariable String serviceInstanceId,
            @RequestBody AdminDeleteRequest request) { // Admin 需要填写理由
        
        // Admin 不需要 verifyOwner，因为他是神
        // 但需要根据 serviceInstanceId 反查出它属于哪个 tenantId
        String targetTenantId = inventoryService.getTenantIdByService(serviceInstanceId);

        deletionProducer.sendDeletionRequest(targetTenantId, serviceInstanceId, 
            "ADMIN_FORCE_DELETE: " + request.getReason()); // 记录是 Admin 删的
        
        return ResponseEntity.accepted().build();
    }
}

B. Kafka Message Payload 更新
Payload 里必须明确 Initiator (发起人)。这对于 Audit Log (审计日志) 至关重要。如果出事了，你得知道是用户自己手滑删的，还是管理员删的。
Updated Kafka Message:
{
  "traceId": "trace-999",
  "key": "tenant-12345",
  "payload": {
    "tenantId": "tenant-12345",
    "serviceInstanceId": "srv-abc-001",
    "serviceType": "cloud-storage",
    
    // --- 新增/修改部分 ---
    "initiator": {
        "userId": "user_999",      // 实际点按钮的人
        "role": "ADMIN",           // 他的角色
        "ipAddress": "192.168.1.1" // 安全审计需要
    },
    "reason": "Violation of ToS",  // 或者是 "User request"
    "isForceDelete": true          // 如果是 Admin，可能跳过某些软删除检查
    // -------------------
  }
}

C. Notification 逻辑变更
通知系统需要变聪明。
 * Case 1 (User deletes self): 发送 "Goodbye, your service is deleted."
 * Case 2 (Admin deletes User):
   * To Admin: "Operation successful. Service X deleted."
   * To User: (必须发) "Your service X was deleted by Administrator. Reason: Violation of ToS."
代码逻辑 (Result Consumer):
public void handleCompletion(ServiceDeletionEntity entity, boolean success) {
    if (!success) {
        // ... handle failure
        return;
    }

    // 检查是谁发起的
    if ("ADMIN".equals(entity.getInitiatorRole())) {
        // 1. 通知 Admin (操作确认)
        notifyAdmin(entity.getInitiatorUserId(), "Deletion Complete");
        
        // 2. 通知无辜的 User (被动通知)
        String userEmail = userService.getEmailByTenant(entity.getTenantId());
        notifyUser(userEmail, "Your service was removed by admin. Reason: " + entity.getReason());
    } else {
        // 常规通知
        notifyUser(entity.getUserEmail(), "Your request is complete.");
    }
}

3. 安全性总结 (Security Checklist)
针对这种双角色系统，你在设计 API 时必须注意：
 * IDOR (Insecure Direct Object Reference) 防护:
   * 这是最容易犯的错。普通用户调用 DELETE /services/123。
   * 代码里通过 @PreAuthorize 只能判断他是不是 User，不能判断 123 也是不是他的。
   * 必须在 Service 层加逻辑：SELECT * FROM services WHERE id=123 AND owner_id = current_user_id。如果查不到，抛出 403。
 * Least Privilege (最小权限原则):
   * Admin 的 Token 威力太大。建议给 Admin 的操作增加 MFA (多因素认证)，或者针对删除这种高危操作，要求 Admin 再次输入密码 (Sudo mode)。
 * Audit Trail (审计追踪):
   * Admin 的所有 DELETE 操作必须写入一张不可篡改的 audit_logs 表。
   * 记录：Admin A deleted Service B belonging to User C at Time T.
总结变更点
| 组件 | User (普通) 操作 | Admin (管理员) 操作 |
|---|---|---|
| API Endpoint | /services/{id} | /admin/services/{id} |
| Auth Check | JWT Role = USER + Resource Ownership Check | JWT Role = ADMIN (Skip ownership check) |
| Kafka Message | initiator: {role: USER} | initiator: {role: ADMIN, reason: "..."} |
| Notification | 发给 User 自己 | 发给 Admin (Ack) AND User (Alert) |
| Airflow | 无感知 (Payload 包含 tenantId 即可) | 无感知 |
