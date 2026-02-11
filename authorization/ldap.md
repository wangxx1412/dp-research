从 Okta 转向 **LDAP**（如 Microsoft Active Directory 或 OpenLDAP）最大的变化在于：LDAP 是通过 **TCP 协议（通常在 VPC 内）** 连接的，而不是像 Okta 那样通过 REST API。

作为一名拥有 6 年经验的 SDE，在处理这种架构迁移时，你需要重点考虑 **网络连通性（VPC）** 和 **连接池管理**。

---

### 1. 架构调整：从 Public 到 VPC

由于 LDAP 服务器通常位于企业内网或私有子网，你的 Lambda 函数必须配置 **VPC 访问权限** 才能触达 LDAP 端口（默认 389 或 LDAPS 636）。

---

### 2. Java Spring LDAP 实现

在 Spring 中，最优雅的方式是使用 `spring-boot-starter-data-ldap`。

#### Maven 依赖 (pom.xml)

```xml
<dependency>
    <groupId>org.springframework.boot</groupId>
    <artifactId>spring-boot-starter-data-ldap</artifactId>
</dependency>

```

#### LDAP 服务类逻辑

```java
@Service
public class LdapAuthService {

    @Autowired
    private LdapTemplate ldapTemplate;

    // [PLACEHOLDER] 从环境变量读取 Base DN (例如: ou=users,dc=example,dc=com)
    @Value("${ldap.base.dn}")
    private String baseDn;

    public boolean authenticate(String username, String password) {
        // [CUSTOM] 构造用户完整的 DN (Distinguished Name)
        // 注意：根据 LDAP 目录结构，这里可能需要先根据 username 搜索用户 DN
        String userDn = String.format("uid=%s,%s", username, baseDn);

        try {
            // 使用用户凭据尝试进行 Bind 认证
            ldapTemplate.authenticate(LdapUtils.emptyLdapName(),
                                      String.format("(uid=%s)", username),
                                      password);
            return true;
        } catch (Exception e) {
            // [CUSTOM] 记录失败原因（密码错误、用户不存在等）
            return false;
        }
    }

    public Map<String, String> getUserAttributes(String username) {
        // [PLACEHOLDER] 搜索用户属性以用于后续的 S3 路径映射
        // 例如：获取用户所属的部门或自定义字段
        return ldapTemplate.search(
            query().where("uid").is(username),
            (AttributesMapper<Map<String, String>>) attrs -> {
                Map<String, String> map = new HashMap<>();
                map.put("department", attrs.get("ou").get().toString());
                return map;
            }
        ).stream().findFirst().orElse(Collections.emptyMap());
    }
}

```

---

### 3. API 设计与 Ticket 核心逻辑

你的 Controller 逻辑基本保持一致，但需要确保 LDAP 搜索的高效性。

```java
@RestController
@RequestMapping("/v1/transfer")
public class LdapIdpController {

    @Autowired
    private LdapAuthService ldapService;

    @GetMapping("/auth")
    public ResponseEntity<Map<String, Object>> handleAuth(
            @RequestParam String username,
            @RequestHeader(value = "Password", required = false) String password) {

        // 1. LDAP 认证
        if (!ldapService.authenticate(username, password)) {
            return ResponseEntity.status(403).build();
        }

        // 2. 获取属性映射 S3 路径
        var attrs = ldapService.getUserAttributes(username);

        // [CUSTOM] 动态 S3 路径逻辑
        // 假设根据部门 (OU) 分配桶路径
        String dept = attrs.getOrDefault("department", "default");
        String s3Target = String.format("/company-data/depts/%s/%s", dept, username);

        Map<String, Object> response = new HashMap<>();
        response.put("Role", "arn:aws:iam::123456789012:role/LDAP-SFTP-Role");
        response.put("HomeDirectoryType", "LOGICAL");
        response.put("HomeDirectoryDetails", String.format("[{\"Entry\": \"/\", \"Target\": \"%s\"}]", s3Target));

        return ResponseEntity.ok(response);
    }
}

```

---

### 4. 需要详细注释与 Custom 的地方

#### A. Lambda 性能与连接池

- **问题：** LDAP 连接握手较慢。
- **Custom 建议：** 在 `LdapContextSource` 中配置 **Pooling**。在 Lambda 环境下，尽量复用连接以减少延迟。
- **代码占位符：**

```java
// [PLACEHOLDER] 配置 ContextSource 时启用连接池
contextSource.setPooled(true);

```

#### B. 匿名搜索与 Manager Bind

- **问题：** 许多 LDAP 不允许匿名搜索。你可能需要先用一个“管理账号” Bind，搜到用户 DN 后，再用用户密码重新认证。
- **不确定点：** 你的 LDAP 是否允许直连认证？如果不允许，你需要两步走。

#### C. 安全传输 (LDAPS)

- **重要：** 生产环境严禁使用 389 端口传输明文密码。
- **Custom 建议：** 必须使用 636 端口 (LDAPS)。你需要将 LDAP 服务器的 CA 证书导入到 Java 的 **TrustStore** 中，或者在 Spring 配置中信任该证书。

---

### 5. Terraform 关键变动

由于 LDAP 在内网，Terraform 需要增加 VPC 配置：

```hcl
resource "aws_lambda_function" "ldap_auth_lambda" {
  # ... 其他配置 ...

  vpc_config {
    # [PLACEHOLDER] 必须在能访问 LDAP Server 的子网内
    subnet_ids         = [var.private_subnet_id]
    security_group_ids = [aws_security_group.lambda_ldap_sg.id]
  }

  environment {
    variables = {
      LDAP_URL     = "ldaps://your-ldap-server.internal:636"
      LDAP_BASE_DN = "dc=example,dc=com"
    }
  }
}

# [CUSTOM] 安全组必须放行 Lambda 到 LDAP 的出口流量
resource "aws_security_group_rule" "allow_ldap_out" {
  type              = "egress"
  from_port         = 636
  to_port           = 636
  protocol          = "tcp"
  cidr_blocks       = ["10.0.0.0/8"] # LDAP 所在的内网网段
  security_group_id = aws_security_group.lambda_ldap_sg.id
}

```

### 交付建议 (Next Step)

LDAP 的 **TrustStore/SSL 证书处理** 在 Java Lambda 中通常比较繁琐（需要将证书打包进镜像或放在 S3 动态加载），你想让我详细说明如何**在 Lambda 环境下配置 LDAPS 的 SSL 证书**吗？

在 AWS Lambda 环境下处理 Java 的 LDAPS（SSL）证书是一个典型的难题，因为 Lambda 的运行环境是只读的（除了 `/tmp`），且你不能像在传统服务器上那样直接运行 `keytool` 命令来永久修改 JVM 的 `cacerts`。

作为 SDE，推荐使用 **“程序化动态加载”** 或 **“自定义 TrustStore 路径”** 的方案。

---

### 1. 核心挑战：Java 信任链

当你的 Java 代码尝试连接 `ldaps://` 时，JVM 会检查服务器证书是否由受信任的 CA 签发。默认情况下，它只信任内置的公共 CA。由于你的 LDAP 服务器通常是内部私有的，你需要手动将 **根证书 (Root CA)** 或 **中间证书** 注入 JVM。

---

### 2. 方案 A：打包自定义 TrustStore (推荐)

这是最稳健的方案。将证书导入一个特定的 `.jks` 文件，将其放入 Spring 项目的 `src/main/resources` 下，随 JAR 包一起上传。

#### 第一步：生成 JKS 文件 (本地执行)

```bash
keytool -import -alias ldap-ca -file internal-ca.crt -keystore ldap-truststore.jks -storepass changeit

```

#### 第二步：Spring Boot 配置

在 `application.yml` 中，你需要告诉 JVM 使用这个文件：

```yaml
spring:
  ldap:
    urls: ldaps://your-ldap-server.internal:636
    base: dc=example,dc=com
    # [CUSTOM] LDAP 连接配置
    context-source:
      base-environment-properties:
        java.naming.ldap.factory.socket: com.example.config.CustomSSLSocketFactory # 如果需要跳过主机名验证
```

#### 第三步：Java 代码中初始化 TrustStore

在 Lambda 启动阶段（例如在 `SpringApplication.run` 之前或在配置类中），通过系统变量指定路径。

```java
@Configuration
public class LdapSslConfig {

    @PostConstruct
    public void init() throws IOException {
        // [CUSTOM] 将 resources 里的 jks 文件拷贝到 /tmp，因为 JVM 有时无法直接读取 JAR 内的 jks 路径
        File trustStoreFile = new File("/tmp/ldap-truststore.jks");
        try (InputStream is = new ClassPathResource("ldap-truststore.jks").getInputStream()) {
            Files.copy(is, trustStoreFile.toPath(), StandardCopyOption.REPLACE_EXISTING);
        }

        // [PLACEHOLDER] 设置全局 JVM 信任库路径
        System.setProperty("javax.net.ssl.trustStore", "/tmp/ldap-truststore.jks");
        System.setProperty("javax.net.ssl.trustStorePassword", "changeit");
    }
}

```

---

### 3. 方案 B：代码动态加载（无需 JKS 文件）

如果你不想维护 JKS 文件，可以从 **AWS Secrets Manager** 读取证书字符串，并在内存中构建 `SSLContext`。

```java
public SSLContext createSslContext(String certificateContent) throws Exception {
    // [PLACEHOLDER] 将 String 格式的证书转换为 X509Certificate
    CertificateFactory cf = CertificateFactory.getInstance("X.509");
    Certificate ca = cf.generateCertificate(new ByteArrayInputStream(certificateContent.getBytes()));

    // 创建一个包含该证书的 KeyStore
    KeyStore keyStore = KeyStore.getInstance(KeyStore.getDefaultType());
    keyStore.load(null, null);
    keyStore.setCertificateEntry("ldap-ca", ca);

    // [CUSTOM] 初始化 TrustManager
    TrustManagerFactory tmf = TrustManagerFactory.getInstance(TrustManagerFactory.getDefaultAlgorithm());
    tmf.init(keyStore);

    SSLContext sslContext = SSLContext.getInstance("TLS");
    sslContext.init(null, tmf.getTrustManagers(), null);
    return sslContext;
}

```

---

### 4. 常见坑点 (Pitfalls)

1. **主机名验证 (Hostname Verification):**
   LDAPS 默认要求证书里的 Common Name (CN) 必须与你的 `LDAP_URL` 匹配。如果是内部测试环境经常报错 `java.security.cert.CertificateException: No subject alternative names matching IP address...`。

- **解决：** 生产环境务必修正证书。测试环境可自定义 `SSLSocketFactory` 来绕过（但不要带入 Prod）。

2. **Lambda 冷启动性能：**
   建立 SSL 连接非常耗时（握手开销）。

- **解决：** 确保在 Lambda 类的构造函数或静态代码块中初始化 `LdapContextSource`，利用 Lambda 的执行上下文重用功能。

3. **VPC 端点：**
   即使 SSL 调通了，如果安全组（Security Group）没有放行 636 端口的出站流量，也会报 `Connect Timeout`。

### 5. Ticket 完成标准 (Definition of Done)

- [ ] **配置化：** 证书密码和 LDAP 路径均存放在 AWS SSM Parameter Store。
- [ ] **安全性：** 严禁在代码中硬编码任何证书或密码。
- [ ] **日志：** 打印 SSL 握手失败的详细原因（使用 `-Djavax.net.debug=ssl,handshake` 参数在开发阶段调试）。

**下一步建议：**
你现在的 API 设计已经涵盖了 **Auth、LDAP 集成和 SSL 安全**。需要我帮你写一个 **GitHub Actions 或 GitLab CI 的脚本**，自动化完成“打包证书 -> 构建 JAR -> 部署到 AWS”的流程吗？
