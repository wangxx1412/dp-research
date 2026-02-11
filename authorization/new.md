这完全改变了游戏规则。现在的架构不再是简单的“去验证”，而是一个 “代理适配器 (Proxy Adapter)” 模式。
你的 AWS Lambda 实际上充当了一个 中间人：它把 SFTP 的“老式”凭据（User/Pass）转换成现代 App 能听懂的 OAuth 请求，然后把 App 返回的业务数据（Role/Policy）翻译回 AWS Transfer Family 能听懂的格式。
这是一个非常经典的 Legacy Protocol to Modern Auth Bridge 设计。
1. API Design Ticket (设计文档)
Ticket 标题:
[Backend] Implement Transfer Family Lambda Adapter for OAuth App Integration
背景 (Context):
AWS Transfer Family (SFTP) 接收到用户连接请求。我们需要通过 Lambda 拦截该请求，使用用户提供的凭据向现有的后端 App (通过 API Gateway) 进行 OAuth 认证，并获取该用户的 S3 IAM Role 和 Scope-down Policy。
架构流程 (Flow):
 * Ingest: Lambda 接收 Transfer Family 的 username & password。
 * Step 1 - Auth: Lambda 调用 App 的 Token Endpoint (交换凭据换取 Access Token)。
 * Step 2 - Config: Lambda 使用 Access Token 调用 App 的 User Profile Endpoint。
 * Translate: App 返回 S3 Role ARN 和 Policy JSON，Lambda 将其转换为 Transfer Family 响应格式。
接口契约 (Contract):
 * 输入 (From AWS): username, password (User Input)
 * 中间交互 (With App):
   * POST /oauth/token (Payload: user/pass -> Return: access_token)
   * GET /api/user/sftp-config (Header: Bearer {token} -> Return: { "roleArn": "...", "policy": "..." })
 * 输出 (To AWS):
   {
  "Role": "arn:aws:iam::...", 
  "Policy": "{ ...JSON Escaped Policy... }",
  "HomeDirectory": "/bucket/user/path" 
}

2. Java Spring 代码实现
我们将使用 WebClient 来处理链式 API 调用。
A. 数据模型 (DTOs)
// 1. App 返回的 Token 响应
record AppTokenResponse(
    @JsonProperty("access_token") String accessToken, 
    @JsonProperty("token_type") String tokenType
) {}

// 2. App 返回的用户 S3 配置
record AppUserSftpConfig(
    String iamRoleArn,      // App 告诉我们该用户用哪个 Role
    String scopeDownPolicy, // App 生成的 JSON 策略字符串
    String s3BucketPath     // 用户的主目录
) {}

B. 核心适配器逻辑 (Service)
@Service
@RequiredArgsConstructor
public class SftpAdapterService {

    private final WebClient webClient; // [PLACEHOLDER] 已配置好 BaseURL 指向你的 API Gateway

    public Map<String, Object> processLogin(String username, String password) {
        
        // --- Step 1: 去 App 拿 Token (OAuth ROPC 模式或类似) ---
        // [CUSTOM] 这里的 URL 和 Body 取决于你们 App 具体要求的 OAuth 格式
        AppTokenResponse tokenResp = webClient.post()
            .uri("/oauth/token")
            .bodyValue(Map.of(
                "grant_type", "password",
                "username", username,
                "password", password
            ))
            .retrieve()
            .onStatus(HttpStatusCode::isError, resp -> Mono.error(new RuntimeException("Auth Failed")))
            .bodyToMono(AppTokenResponse.class)
            .block(); // Lambda 中通常可以使用 block()，因为是同步响应模型

        if (tokenResp == null || tokenResp.accessToken() == null) {
            throw new RuntimeException("No access token received");
        }

        // --- Step 2: 拿着 Token 去 App 拿 S3 配置 ---
        // [CUSTOM] 调用后端 API 获取该用户的 IAM Role 和 Policy
        AppUserSftpConfig userConfig = webClient.get()
            .uri("/api/user/sftp-config") // [PLACEHOLDER] 目标 API 路径
            .header("Authorization", "Bearer " + tokenResp.accessToken())
            .retrieve()
            .bodyToMono(AppUserSftpConfig.class)
            .block();

        // --- Step 3: 组装 AWS Transfer Family 响应 ---
        return buildAwsResponse(userConfig);
    }

    private Map<String, Object> buildAwsResponse(AppUserSftpConfig config) {
        Map<String, Object> response = new HashMap<>();
        
        // 1. Role: 必须是 AWS IAM Role ARN
        response.put("Role", config.iamRoleArn());

        // 2. Policy: (可选) 这是一个 Scope-down Policy
        // [IMPORTANT] 这个 Policy 会在 Role 的权限基础上做“交集”，进一步限制用户只能访问特定文件夹
        // App 返回的通常是一个 JSON String，如果不是 String 需要在此序列化
        if (config.scopeDownPolicy() != null) {
            response.put("Policy", config.scopeDownPolicy());
        }

        // 3. HomeDirectory: 用户登录后的根目录
        response.put("HomeDirectory", config.s3BucketPath()); // e.g., "/my-bucket/users/bob"

        return response;
    }
}

C. Lambda 入口 (Controller)
@RestController
public class LambdaHandler {

    @Autowired
    private SftpAdapterService adapterService;

    @GetMapping("/auth") // API Gateway Proxy Integration
    public ResponseEntity<Map<String, Object>> handleRequest(
            @RequestHeader(value = "username", required = false) String username,
            @RequestHeader(value = "password", required = false) String password) {

        // [CUSTOM] 健壮性检查
        if (username == null || password == null) {
            return ResponseEntity.status(401).build();
        }

        try {
            Map<String, Object> awsResponse = adapterService.processLogin(username, password);
            return ResponseEntity.ok(awsResponse);
        } catch (Exception e) {
            // [CUSTOM] 记录日志，注意不要打印 password
            System.err.println("Login failed for user: " + username + " Error: " + e.getMessage());
            return ResponseEntity.status(403).build(); // 返回 403 拒绝 SFTP 登录
        }
    }
}

3. 核心解释与关键点 (The "Why" and "How")
这个设计的精髓在于 Trust Chain（信任链） 的传递：
 * OAuth ROPC (Resource Owner Password Credentials):
   * 因为 SFTP 客户端（如 FileZilla）只给你一个输入框输入密码，它弹不出浏览器让你扫码。
   * 所以，Lambda 必须代表用户，拿着明文密码去 App 换 Token。这是 OAuth 协议中专门为这种“非浏览器客户端”设计的模式。
   * 风险点： 你的 Lambda 会短暂接触用户明文密码。确保日志里千万别把 password 打印出来。
 * IAM Policy vs Scope-Down Policy:
   * 你提到 App 会返回 Policy。这是 AWS Transfer Family 最强大的功能之一。
   * IAM Role (粗粒度): 通常所有 SFTP 用户共用同一个 IAM Role（比如 SftpUserRole），这个 Role 有权访问整个 Bucket。
   * Policy (细粒度): App 动态生成一段 JSON Policy（Scope-Down Policy），限制这个特定用户 只能 访问 /bucket/user/abc/*。
   * Lambda 的工作： 它是搬运工。它把 App 生成的这段限制性 JSON 塞给 AWS Transfer Family，AWS 会在运行时实时应用这个限制。
 * App 端的 API Gateway:
   * Lambda 去调用 App 时，是通过 API Gateway 走的。
   * [PLACEHOLDER] 确保 Lambda 所在的 VPC (如果有) 能访问该 API Gateway。如果是公网 API Gateway，Lambda 需要 NAT Gateway；如果是私有 API Gateway，需要 VPC Endpoint。
4. 下一步 Check List
 * [ ] 后端 App 改造: 你的后端 App 需要一个新的 API (/api/user/sftp-config)，它不仅要验证 Token，还要知道 "AWS IAM Policy JSON 怎么写" 并返回给 Lambda。
 * [ ] 超时设置: 整个流程（Lambda -> App Auth -> App Config -> Return）必须在 AWS Transfer Family 的超时限制（通常是 30 秒，但建议控制在 5-10 秒）内完成。
 * [ ] 网络: 确认 Lambda 出去的 IP 是否在 App API Gateway 的白名单里。
这个设计清晰吗？如果你的 App 返回的 Policy 格式很特殊，或者需要我在代码里加一段生成 Policy JSON 的逻辑，请告诉我。

清楚明确。这里是 AWS Transfer Family 调用你的 API Gateway（以及你的 Spring Boot Controller）时的标准 HTTP 契约。
请注意：AWS Transfer Family 不会 发送 JSON Body，所有的参数都是通过 HTTP Headers 或 Query Parameters 传递的。
1. 请求 (Request)
方向： AWS Transfer Family Service -> API Gateway -> Your Spring Boot App
当你在 AWS Console 配置 Custom Identity Provider 时，通常使用 GET 方法。
HTTP 请求示例 (Raw HTTP)
GET /api/v1/transfer/auth?username=jdoe&serverId=s-1234567890abcdef0 HTTP/1.1
Host: api-gateway-id.execute-api.us-east-1.amazonaws.com
User-Agent: Transfer Family
Password: MySecretPassword123!   <-- 关键：密码在 Header 中
Protocol: SFTP
SourceIp: 203.0.113.5

Spring Controller 映射
为了接收上面的请求，你的 Controller 方法签名应该是这样的：
@GetMapping("/auth")
public ResponseEntity<Map<String, Object>> handleAuth(
    // URL Query Parameters
    @RequestParam("username") String username,
    @RequestParam(value = "serverId", required = false) String serverId,

    // HTTP Headers
    @RequestHeader("Password") String password,
    @RequestHeader(value = "Protocol", defaultValue = "SFTP") String protocol,
    @RequestHeader(value = "SourceIp", required = false) String sourceIp
) { ... }

2. 成功响应 (Success Response)
场景： 验证通过，OAuth Token 获取成功，App 返回了 Role 和 Policy。
HTTP 响应示例 (Raw HTTP)
 * Status Code: 200 OK
 * Content-Type: application/json
<!-- end list -->
HTTP/1.1 200 OK
Content-Type: application/json

{
  "Role": "arn:aws:iam::123456789012:role/SftpUserAccessRole",
  "Policy": "{\"Version\": \"2012-10-17\",\"Statement\": [{\"Sid\": \"AllowListingOfUserFolder\",\"Action\": [\"s3:ListBucket\"],\"Effect\": \"Allow\",\"Resource\": [\"arn:aws:s3:::my-bucket\"],\"Condition\": {\"StringLike\": {\"s3:prefix\": [\"home/jdoe/*\",\"home/jdoe\"]}}},{\"Sid\": \"HomeDirObjectAccess\",\"Effect\": \"Allow\",\"Action\": [\"s3:PutObject\",\"s3:GetObject\",\"s3:DeleteObject\",\"s3:GetObjectVersion\"],\"Resource\": \"arn:aws:s3:::my-bucket/home/jdoe/*\"}]}",
  "HomeDirectoryType": "LOGICAL",
  "HomeDirectoryDetails": "[{\"Entry\": \"/\", \"Target\": \"/my-bucket/home/jdoe\"}]"
}

关键字段解释：
 * Role (必填):
   * 这是 AWS Transfer Family 用来代表用户访问 S3 的 IAM Role ARN。
   * 注意： 这个 Role 必须有 Trust Relationship 允许 transfer.amazonaws.com Assume 它。
 * Policy (选填，但在你的场景中很重要):
   * 这是一个 JSON 字符串（不是 JSON 对象）。你需要把 Policy JSON 转义成字符串放进去。
   * 这就是 Scope-Down Policy。它会限制上面的 Role，确保用户只能访问他自己的文件夹。如果不传这个字段，用户就拥有 Role 定义的所有权限。
 * HomeDirectoryType & HomeDirectoryDetails:
   * 用于构建 逻辑目录 (Chroot)。
   * Entry: "/" 表示用户登录 SFTP 后看到的根目录。
   * Target: "/my-bucket/home/jdoe" 是 S3 的实际物理路径。
   * 如果不使用逻辑目录，可以直接用 "HomeDirectory": "/my-bucket/home/jdoe"，但那样用户能看到 S3 的 Bucket 名称，不推荐。
3. 失败响应 (Failure Response)
场景： 密码错误，或者 OAuth Token 获取失败。
HTTP 响应示例
AWS Transfer Family 只看 HTTP Status Code。
 * Status Code: 403 Forbidden (或者 401 Unauthorized，但 AWS 推荐 403)
 * Body: 空 (AWS 会忽略 Body 内容)
<!-- end list -->
HTTP/1.1 403 Forbidden
Content-Type: application/json

{}

4. 特殊情况：公钥认证 (Public Key Auth)
如果用户是通过 SSH Key 登录而不是密码：
 * 请求变动： Header 中没有 Password。
 * 响应变动： 不需要返回 Role 和 Policy 立即给 AWS，而是返回一个公钥列表，让 AWS 自己去比对。或者你自己在 Lambda 里比对完，直接返回 Role (如果是 API Gateway 方法，通常是后者)。
但基于你之前的描述（通过 OAuth 换 Token），你走的是 Password Auth 流程，所以请忽略公钥情况，专注于处理 Password Header 即可。
