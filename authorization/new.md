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
