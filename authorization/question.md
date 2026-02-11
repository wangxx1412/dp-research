在我的回复中，`[PLACEHOLDER]` 和 `[CUSTOM]` 是为了帮你快速区分 **“需要填入的固定配置”** 和 **“需要你发挥的业务逻辑”**。

作为一个有经验的 SDE，你一眼就能看出这些是代码模板中的“填空题”，但为了严谨起见，这里是它们的详细定义：

---

### 1. `[PLACEHOLDER]` (占位符)

这代表的是**具体的环境参数或资源标识符**。这些值通常不涉及复杂的逻辑，但它们是让程序运行起来的“钥匙”。

- **含义：** “这里需要填入你 AWS 环境或 LDAP 服务器的真实值。”
- **你通常需要做什么：** \* 从 AWS 控制台复制 ARN（如 IAM Role 的 ARN）。
- 从环境变量或 Secret Manager 中读取具体的配置。
- 填入具体的域名（如 `your-company.ldap.com`）。

- **例子回顾：**
- `response.put("Role", "arn:aws:iam::YOUR_ACCOUNT_ID:role/...");` —— 这里必须换成你真实的 AWS 账号 ID。
- `System.setProperty("...trustStorePassword", "changeit");` —— 这里应换成你生成 JKS 文件时设置的密码。

---

### 2. `[CUSTOM]` (定制化逻辑)

这代表的是**核心业务决策或复杂的代码实现点**。这是体现你架构设计能力的地方，因为每个公司的业务规则（Business Rules）都不同。

- **含义：** “这里无法写死，因为取决于你的具体需求。”
- **你通常需要做什么：**
- **编写映射逻辑：** 比如如何根据 LDAP 的 `department` 字段决定用户进入 S3 的哪个文件夹。
- **处理异常：** 比如当 LDAP 认证失败时，是直接返回 403，还是记录特定日志并触发报警。
- **实现协议转换：** 比如如何处理 LDAP 证书的主机名验证（Hostname Verification）。

- **例子回顾：**
- `// [CUSTOM] 逻辑路径映射：防止用户访问他人的文件夹` —— 这里的代码决定了 SFTP 用户的“隔离墙”怎么造，是按 `username` 隔开还是按 `project_id` 隔开。

---

### 总结对比表

| 标记                | 性质          | 关注点                   | 处理方式                    |
| ------------------- | ------------- | ------------------------ | --------------------------- |
| **`[PLACEHOLDER]`** | **静态/配置** | 外部资源的 ID、URL、密码 | 查找并替换 (Find & Replace) |
| **`[CUSTOM]`**      | **动态/逻辑** | 业务流程、算法、错误处理 | 编码实现 (Implementation)   |

---

### 💡 如何在你的 Ticket 中使用它们？

在把这些内容写进你的 Jira/Confluence Ticket 时，你可以直接保留这些标记，或者将其转换为 **TODO List**。例如：

> **TODO:**
>
> 1. 更新 `[PLACEHOLDER]` 中的 IAM Role ARN，确保其具有 S3 访问权限。
> 2. 实现 `[CUSTOM]` 逻辑：根据 `ldap_groups` 动态分配 S3 Bucket 路径。

**下一步建议：**
如果你正在整理最终的 Design Doc，需要我帮你把这些代码整理成一个**可以直接运行的 Spring Boot Controller 类**（把这些占位符转为 `@Value` 注入的形式）吗？

既然你准备好把这些碎片整理成一个正式的工程，这里是一个完整的、符合生产标准的 **Java Spring Boot 结构**。

这个结构将配置（Placeholders）通过 `@Value` 注入，并预留了扩展业务逻辑（Custom）的空间。

### 1. 核心控制器：`TransferIdpController.java`

这是 API Gateway 直接调用的入口。它负责协调认证和权限生成。

```java
@RestController
@RequestMapping("/api/v1/transfer")
public class TransferIdpController {

    private final LdapAuthService ldapAuthService;
    private final String sftpUserRoleArn;

    // [PLACEHOLDER] 通过构造函数注入配置，方便测试
    public TransferIdpController(
            LdapAuthService ldapAuthService,
            @Value("${aws.sftp.user-role-arn}") String sftpUserRoleArn) {
        this.ldapAuthService = ldapAuthService;
        this.sftpUserRoleArn = sftpUserRoleArn;
    }

    @GetMapping("/auth")
    public ResponseEntity<Map<String, Object>> authenticate(
            @RequestParam("username") String username,
            @RequestHeader(value = "Password", required = false) String password) {

        // 1. 调用 LDAP 认证逻辑
        if (!ldapAuthService.authenticate(username, password)) {
            return ResponseEntity.status(HttpStatus.FORBIDDEN).build();
        }

        // 2. 获取用户属性（用于动态路径）
        Map<String, String> userAttrs = ldapAuthService.getUserAttributes(username);

        // [CUSTOM] 业务逻辑：根据 LDAP 属性计算 S3 路径
        // 比如：/my-bucket/departments/{dept}/{username}
        String dept = userAttrs.getOrDefault("ou", "general");
        String s3Target = String.format("/my-sftp-bucket/home/%s/%s", dept, username);

        // 3. 构造符合 AWS Transfer 契约的响应
        Map<String, Object> response = new HashMap<>();
        response.put("Role", sftpUserRoleArn);
        response.put("HomeDirectoryType", "LOGICAL");
        response.put("HomeDirectoryDetails",
            String.format("[{\"Entry\": \"/\", \"Target\": \"%s\"}]", s3Target));

        return ResponseEntity.ok(response);
    }
}

```

---

### 2. LDAP 服务类：`LdapAuthService.java`

处理复杂的 LDAP 交互和 SSL 握手。

```java
@Service
public class LdapAuthService {

    private final LdapTemplate ldapTemplate;

    public LdapAuthService(LdapTemplate ldapTemplate) {
        this.ldapTemplate = ldapTemplate;
    }

    public boolean authenticate(String username, String password) {
        if (password == null || password.isEmpty()) return false;

        try {
            // [CUSTOM] 这里的 Filter 需要根据你 LDAP 的 Schema 调整
            // 常见的有 (uid={0}) 或 (sAMAccountName={0})
            ldapTemplate.authenticate("", String.format("(uid=%s)", username), password);
            return true;
        } catch (Exception e) {
            // Log error: Authentication failed for user
            return false;
        }
    }

    public Map<String, String> getUserAttributes(String username) {
        // [CUSTOM] 提取你需要的 LDAP 字段，比如 部门(ou), 邮箱(mail) 等
        return ldapTemplate.search(
            query().where("uid").is(username),
            (AttributesMapper<Map<String, String>>) attrs -> {
                Map<String, String> res = new HashMap<>();
                if (attrs.get("ou") != null) res.put("ou", attrs.get("ou").get().toString());
                return res;
            }
        ).stream().findFirst().orElse(Collections.emptyMap());
    }
}

```

---

### 3. 环境配置文件：`application.yml`

这是填入你 `[PLACEHOLDER]` 真实值的地方。

```yaml
spring:
  ldap:
    urls: ldaps://your-internal-ldap:636
    base: dc=example,dc=com
    username: cn=admin,dc=example,dc=com # 用于搜索用户的管理账号
    password: ${LDAP_ADMIN_PASSWORD} # 从环境变量读取
    template:
      ignore-partial-result-exception: true

aws:
  sftp:
    # [PLACEHOLDER] 填入你 Terraform 创建的 IAM Role ARN
    user-role-arn: "arn:aws:iam::123456789012:role/SFTP-S3-Access-Role"

# [CUSTOM] 如果是自签名证书，需要在启动参数中指定 TrustStore 路径
# -Djavax.net.ssl.trustStore=/tmp/ldap.jks
```

---

### 4. 给你的 Ticket 补充建议

作为一名 SDE，在提交这个 Ticket 时，建议在 **Testing Plan** 部分增加以下场景，这会让你的 Design Review 显得非常周全：

1. **并发测试：** 当 50 个用户同时登录 SFTP 时，LDAP 连接池是否会耗尽？（提示：Spring LDAP 默认连接池配置）。
2. **安全扫描：** 确保密码在日志中被 Mask（脱敏），不要在报错信息中打印明文。
3. **网络隔离：** 验证 Lambda 是否只能通过 636 端口访问 LDAP，而不能访问内网其他不相关资源。

---

### 下一步你可以做的是：

既然代码逻辑和部署脚本（Terraform）都初具规模了，你需要我帮你写一个 **README.md** 或者 **Deployment Guide**，用来指导团队其他成员如何把这个 Java 应用打包并部署到 AWS 环境吗？
