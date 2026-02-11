既然确定使用 **Okta** 作为身份提供商（IdP），你的 Java Spring 应用将充当 **桥接器**：它接收来自 AWS Transfer Family 的明文凭据，通过 Okta 的 API 进行验证，并返回 AWS 所需的权限架构（IAM Role/S3 路径）。

由于 SFTP 协议限制，通常无法进行浏览器重定向（如标准的 OAuth2 Authorization Code Flow），因此你需要使用 Okta 的 **Authentication API** 或 **Resource Owner Password Credentials (ROPC) Flow**。

---

### 1. 架构流 (Architectural Flow)

1. **用户**输入 SFTP 用户名/密码。
2. **AWS Transfer Family** 调用 **API Gateway**。
3. **API Gateway** 触发 **Java Lambda (Spring)**。
4. **Java App** 调用 **Okta API** (`/api/v1/authn`) 验证凭据。
5. **Java App** 验证成功后，根据 Okta 返回的 **Groups/Profile** 映射出对应的 S3 桶路径和 IAM Role。
6. **Java App** 返回 JSON 给 AWS Transfer。

---

### 2. Java Spring 代码实现

你需要引入 `okta-auth-java-sdk` 或直接使用 `WebClient` 调用 Okta REST API。

#### Maven 依赖 (pom.xml)

```xml
<dependency>
    <groupId>com.okta.authn.sdk</groupId>
    <artifactId>okta-authn-sdk-api</artifactId>
    <version>2.0.0</version>
</dependency>
<dependency>
    <groupId>com.okta.authn.sdk</groupId>
    <artifactId>okta-authn-sdk-impl</artifactId>
    <version>2.0.0</version>
    <scope>runtime</scope>
</dependency>

```

#### 核心控制器逻辑

```java
@Service
public class OktaAuthService {

    // [PLACEHOLDER] 从环境变量读取 Okta Domain (e.g., https://dev-123.okta.com)
    @Value("${okta.domain}")
    private String oktaDomain;

    public AuthenticationResponse validateWithOkta(String username, String password) {
        // 使用 Okta SDK 进行身份验证
        AuthenticationClient client = AuthenticationClients.builder()
                .setOrgUrl(oktaDomain)
                .build();

        try {
            // [CUSTOM] 这里处理基础身份验证
            // 如果 Okta 开启了 MFA，此流程会返回 'MFA_REQUIRED' 状态
            // 但标准 SFTP 客户端很难处理二次挑战，通常建议 SFTP 专用账户关闭 MFA 或使用公钥
            return client.authenticate(username, password.toCharArray(), null, new SimpleAuthenticationStateHandler());
        } catch (Exception e) {
            // 验证失败（密码错误、账户锁定等）
            return null;
        }
    }
}

@RestController
public class TransferIdpHandler {

    @Autowired
    private OktaAuthService oktaAuthService;

    @GetMapping("/auth")
    public ResponseEntity<Map<String, Object>> handleTransferAuth(
            @RequestParam("username") String username,
            @RequestHeader("Password") String password) {

        // 1. 调用 Okta
        var authResult = oktaAuthService.validateWithOkta(username, password);

        if (authResult == null || !"SUCCESS".equals(authResult.getStatusName())) {
            return ResponseEntity.status(403).build();
        }

        // 2. 映射 AWS 权限
        Map<String, Object> response = new HashMap<>();

        // [PLACEHOLDER] 这里的 Role 必须有权限访问下面的 S3 Bucket
        response.put("Role", "arn:aws:iam::123456789012:role/SFTP-S3-Access-Role");

        // [CUSTOM] 逻辑路径映射：防止用户访问他人的文件夹
        // 假设每个用户在 S3 中有自己的文件夹
        String userS3Path = "/your-bucket-name/home/" + username;

        response.put("HomeDirectoryType", "LOGICAL");
        response.put("HomeDirectoryDetails", List.of(
            Map.of("Entry", "/", "Target", userS3Path)
        ));

        return ResponseEntity.ok(response);
    }
}

```

---

### 3. 需要 Custom 的地方与详细注释

#### A. MFA 处理 (The Multi-Factor Gap)

- **挑战：** SFTP 协议本身不支持弹窗让你输入 Okta 动态验证码。
- **Custom 方案：** 1. **特定策略：** 在 Okta 侧配置策略，对来自 API Gateway 固定 IP 的请求（或特定 Service Account）免除 MFA。

2.  **密码叠加：** 有些公司要求用户输入 `password + token`（如 `password123456`），你需要在 Java 代码中对 `password` 字符串进行截取拆分，分别传递给 Okta 的 `stateToken` 验证接口。

#### B. 动态 Role 映射

- **需求：** 不同部门的用户可能需要不同的 S3 桶权限。
- **Custom 实现：** \* 在 Okta 返回的 `AuthenticationResponse` 中可以获取用户的 `Groups`。
- **代码逻辑：** `if (groups.contains("Finance")) { role = financeRole; }`。不要在代码里写死 ARN，建议存在 **AWS AppConfig** 或 **DynamoDB** 中。

#### C. 公钥验证 (Public Key Auth)

- 如果用户使用 SSH Key 而不是密码：
- AWS Transfer 会传 `username` 但不传 `Password` Header。
- **代码逻辑：** 你需要去 Okta 的 User Profile 中读取自定义字段（如 `sshPublicKey`），然后将其放入响应的 `PublicKeys` 数组中返回给 AWS，AWS 会在本地进行比对。

---

### 4. API Gateway 配置注意项

为了让上述代码正常工作，你在部署时必须注意：

- **Method Request:** 必须允许 `Password` 和 `Protocol` 等自定义 Header 通过。
- **Caching:** 建议开启短时间的 API Gateway 缓存（如 60 秒），防止用户在频繁上传小文件时，每次都去刷 Okta 的 API，导致触发 Okta 的 Rate Limit。

**下一步建议：**
你需要我为你提供具体的 **S3 IAM Policy** 范本，以确保 Transfer Family 获取的 Role 能正确受限于该用户的逻辑目录吗？

为了完成这个 API 设计 Ticket，我们需要将 AWS Transfer Family 的自定义身份验证逻辑从 Python 迁移到 **Java Spring**，并深入集成 **Okta**。

以下是按照标准开发流程为你准备的 **API Design Spec (Ticket)**。

---

## 1. 业务目标与架构图

**目标：** 构建一个身份验证 API，允许用户通过 SFTP 登录 AWS Transfer Family，后端通过 Okta 进行凭据校验，并动态返回该用户的 S3 访问权限（逻辑目录）。

| 组件                    | 职责                                                     |
| ----------------------- | -------------------------------------------------------- |
| **AWS Transfer Family** | 处理 SFTP 连接，通过 API Gateway 触发认证。              |
| **API Gateway**         | 暴露 REST 端点，透传凭据给 Lambda/App。                  |
| **Java Spring App**     | 核心逻辑：验证 Okta 状态 -> 映射 AWS 权限 -> 返回 JSON。 |
| **Okta**                | 身份源 (Source of Truth)，验证用户名和密码。             |

---

### 2. API 接口契约 (Contract)

**端点 (Endpoint):** `GET /auth` (由 API Gateway 路由)

#### 请求参数 (来自 Transfer Family)

这些参数由 API Gateway 通过 Query String 或 Header 传递给你的 Java 应用：

- `username`: 用户登录名。
- `password`: 用户输入的明文密码（仅限密码验证）。
- `serverId`: Transfer 实例 ID。
- `protocol`: 协议类型 (`SFTP`, `FTPS`)。
- `sourceIp`: 客户端 IP（可用于 Okta 网络策略过滤）。

#### 成功响应 (200 OK)

必须严格符合 AWS Transfer Family 的 Schema：

```json
{
  "Role": "arn:aws:iam::123456789012:role/SFTP-Access-Role",
  "HomeDirectoryType": "LOGICAL",
  "HomeDirectoryDetails": "[{\"Entry\": \"/\", \"Target\": \"/my-bucket/users/username\"}]",
  "PublicKeys": []
}
```

---

### 3. Java Spring 核心代码实现

这里使用 **Spring Web** 模式。请注意代码中的 **[PLACEHOLDER]** 和 **[CUSTOM]** 注释。

#### A. 身份验证服务 (Okta Integration)

```java
@Service
public class OktaAuthService {

    // [PLACEHOLDER] 从 AWS Secrets Manager 或环境变量读取 Okta API Token
    @Value("${okta.api.token}")
    private String oktaApiToken;

    @Value("${okta.domain}")
    private String oktaDomain;

    public boolean authenticate(String username, String password) {
        // [UNCERTAINTY] SFTP 不支持 OIDC 重定向，需使用 Okta Authn API (ROPC Flow)
        // [CUSTOM] 建议使用 RestTemplate 或 WebClient 调用 Okta '/api/v1/authn'

        String authUrl = String.format("https://%s/api/v1/authn", oktaDomain);

        // 构造 Okta 要求的 Payload
        Map<String, String> payload = Map.of(
            "username", username,
            "password", password
        );

        try {
            // [PLACEHOLDER] 执行 POST 请求并检查响应状态码是否为 200 (SUCCESS)
            // 注意：如果状态是 'MFA_REQUIRED'，SFTP 流程通常会在这里中断，因为无法二次输入。
            return true; // 模拟验证成功
        } catch (Exception e) {
            return false;
        }
    }
}

```

#### B. 权限映射逻辑 (Logic Mapper)

```java
@RestController
@RequestMapping("/v1/transfer")
public class TransferIdpController {

    @Autowired
    private OktaAuthService oktaAuthService;

    @GetMapping("/authenticate")
    public ResponseEntity<Map<String, Object>> login(
            @RequestParam String username,
            @RequestHeader(value = "Password", required = false) String password) {

        // 1. 调用 Okta 验证
        if (!oktaAuthService.authenticate(username, password)) {
            return ResponseEntity.status(HttpStatus.FORBIDDEN).build();
        }

        // 2. 构造响应
        Map<String, Object> response = new HashMap<>();

        // [PLACEHOLDER] AWS IAM Role ARN - 该 Role 必须拥有 S3 访问权限
        response.put("Role", "arn:aws:iam::YOUR_AWS_ACCOUNT_ID:role/YourSftpRole");

        // [CUSTOM] 逻辑目录设计：实现 Chroot 隔离，防止用户查看到其他人的目录
        // 这里的 Target 路径必须在 S3 中真实存在
        String userHome = "/your-s3-bucket/home/" + username;
        String logicalPathJson = String.format("[{\"Entry\": \"/\", \"Target\": \"%s\"}]", userHome);

        response.put("HomeDirectoryType", "LOGICAL");
        response.put("HomeDirectoryDetails", logicalPathJson);

        return ResponseEntity.ok(response);
    }
}

```

---

### 4. 详细注释：不确定性与定制化点

- **MFA (多因素认证) 的断裂：** \* **不确定点：** Okta 通常强制开启 MFA。但在 SFTP 场景下，用户无法完成手机推送或验证码输入。
- **Custom 建议：** 在 Okta 侧为 SFTP 服务创建专用的 **Network Zone**，并配置策略：如果是来自 API Gateway 的 IP，则跳过 MFA；或者强制用户使用 **SSH Public Key** 认证。

- **权限映射策略 (Role Mapping)：**
- **不确定点：** 所有用户共用一个 IAM Role，还是根据 Okta Group 映射不同的 Role？
- **Custom 建议：** 如果需要 Group 映射，在 Okta 验证成功后，获取 `memberOf` 字段。在代码中维护一个 `Map<String, String> groupToRoleArn`。

- **AWS Transfer Toolkit 的 Java 改写：**
- 那个 Python Toolkit 实际上提供了一套 Terraform 模板来创建 API Gateway。
- **Custom 建议：** 你不需要照搬它的 Python 内部逻辑，只需要确保你的 Java Controller 的 **入参名** 和 **出参 JSON Key** 与它文档中的 HTTP 协议完全一致。

---

### 5. 交付检查清单 (Checklist)

1. [ ] **Okta API 连通性：** 确保 Lambda 的 VPC 能够访问外网（通过 NAT Gateway）。
2. [ ] **IAM Role 信任关系：** 确保你返回的 `Role` 信任 `transfer.amazonaws.com` 服务。
3. [ ] **性能考虑：** Java Spring 在 Lambda 上有冷启动问题，建议开启 **Provisioned Concurrency**。

**下一步：**
你需要我为你写一份用于部署这个 Java 应用的 **Terraform 脚本**，来连接 API Gateway 和 Transfer Family 吗？

既然我们要进入部署阶段，这份 **Terraform** 脚本将作为“粘合剂”，把你的 Java Spring Lambda、API Gateway 和 AWS Transfer Family 连接起来。

核心难点在于 **IAM 权限的传递**：Transfer Family 必须有权调用 API Gateway，而 Lambda 必须能够访问 Okta 并返回正确的 S3 权限。

---

### 1. AWS Transfer Family Server 配置

这是最关键的部分，你需要指定 `identity_provider_type` 为 `API_GATEWAY`。

```hcl
resource "aws_transfer_server" "sftp_server" {
  identity_provider_type = "API_GATEWAY"

  # API Gateway 的调用 URL (由下文定义)
  url = "${aws_api_gateway_stage.prod.invoke_url}${aws_api_gateway_resource.auth.path}"

  # [CUSTOM] 允许 Transfer Family 调用 API Gateway 的角色
  invocation_role = aws_iam_role.transfer_invocation_role.arn

  protocols = ["SFTP"]
  endpoint_type = "PUBLIC" # 如果是内网使用，可改为 VPC

  tags = {
    Name = "Okta-Auth-SFTP-Server"
  }
}

```

---

### 2. IAM 角色：调用的“通行证”

这里有两个核心角色需要配置：

#### A. Transfer 访问 API Gateway 的角色

```hcl
resource "aws_iam_role" "transfer_invocation_role" {
  name = "transfer-family-invocation-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = { Service = "transfer.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "invocation_policy" {
  role = aws_iam_role.transfer_invocation_role.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action   = "execute-api:Invoke"
      Effect   = "Allow"
      Resource = "${aws_api_gateway_rest_api.auth_api.execution_arn}/*"
    }]
  })
}

```

#### B. SFTP 用户执行角色 (User Role)

这是你的 Java API 最终**返回给 AWS** 的那个 Role，它决定了用户登录后能对 S3 做什么。

```hcl
resource "aws_iam_role" "sftp_user_role" {
  name = "sftp-user-access-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = { Service = "transfer.amazonaws.com" }
    }]
  })
}

# [CUSTOM] 限制用户只能访问自己的逻辑目录
resource "aws_iam_role_policy" "sftp_s3_policy" {
  role = aws_iam_role.sftp_user_role.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = [
        "s3:ListBucket",
        "s3:GetBucketLocation"
      ]
      Effect   = "Allow"
      Resource = "arn:aws:s3:::your-bucket-name"
    },
    {
      Action = ["s3:PutObject", "s3:GetObject", "s3:DeleteObject"]
      Effect = "Allow"
      # [PLACEHOLDER] 确保权限范围涵盖所有用户目录
      Resource = "arn:aws:s3:::your-bucket-name/home/*"
    }]
  })
}

```

---

### 3. Java Lambda 环境变量配置

在部署 Lambda 时，你需要注入 Okta 的配置信息。

```hcl
resource "aws_lambda_function" "java_auth_lambda" {
  function_name = "transfer-family-okta-auth"
  handler       = "com.example.StreamLambdaHandler::handleRequest" # Spring Cloud Function 标准 Handler
  runtime       = "java17"
  role          = aws_iam_role.lambda_exec_role.arn
  # ... 其他配置 (s3_bucket, s3_key 等)

  environment {
    variables = {
      # [PLACEHOLDER] Okta API 配置
      OKTA_DOMAIN    = "dev-xxxxxx.okta.com"
      OKTA_API_TOKEN = var.okta_api_token # 建议从 Secrets Manager 读取

      # [PLACEHOLDER] 之前定义的 IAM Role ARN，返回给 Transfer Family 使用
      SFTP_USER_ROLE_ARN = aws_iam_role.sftp_user_role.arn
    }
  }
}

```

---

### 4. 关键 Custom 点总结

1. **Logical Directory (逻辑目录映射)：**
   在 Java 代码中返回 `HomeDirectoryDetails` 时，`Entry` 通常写为 `/`，而 `Target` 指向 S3 路径。

- **注意：** 如果你使用了逻辑目录，S3 中的物理路径必须是 `bucket/home/username`，而用户在 SFTP 客户端看到的根目录 `/` 实际上就是该物理路径。

2. **Okta Rate Limiting：**
   SFTP 客户端（如 FileZilla）可能会同时开启多个连接，导致短时间内触发大量 API 调用。

- **优化：** 在 API Gateway 层开启 **Caching**（缓存），缓存 Key 设置为 `method.request.querystring.username`。

3. **Secrets Manager：**
   千万不要在 Terraform 代码里明文写 Okta API Token。使用 `aws_secretsmanager_secret_version` 来动态注入。

### 接下来建议

你是否需要我为你提供一个 **CloudWatch Log Insight** 的查询语句，以便在上线后排查 Okta 登录失败的原因？
