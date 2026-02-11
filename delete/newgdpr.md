加上 GDPR (General Data Protection Regulation) 的要求，这个设计的复杂度会提升一个维度。作为拥有 6 年经验的 SDE，你需要明白 GDPR 不仅仅是“删数据”，而是关于 合规性 (Compliance)、审计 (Auditability) 和 时效性 (SLA)。
在之前的架构基础上，我们需要引入以下三个关键概念来满足 GDPR：
 * Right to Erasure (被遗忘权): 必须彻底删除，或匿名化 (Anonymization) 到无法还原。
 * Audit Trail (审计追踪): 你必须能证明你删了，且是在规定时间（通常 30 天）内删的。
 * Crypto-Shredding (加密销毁): 针对备份和日志中难以物理删除的数据，采用销毁密钥的方式。
以下是针对 GDPR 优化的架构设计：
1. 核心架构调整：PII隔离与加密销毁
GDPR 最头疼的是 Logs、Backups 和 Kafka Topic 中的数据残留。我们不能为了删一条 Log 去重写整个文件。
策略：Crypto-Shredding (加密粉碎)
 * 设计原则： 所有进入系统的 PII (Personal Identifiable Information) 必须用一个该用户独有的 Key (User Key) 加密。
 * 删除逻辑： 当收到 GDPR 删除请求时，除了执行常规 DB 删除，最终操作是销毁这个 User Key。一旦 Key 没了，备份和日志里的密文就变成了乱码，法律上视为已删除。
2. 数据库模型升级 (Audit Log)
Metadata 表不能包含明文 PII（否则这张表本身就违规了）。我们需要将 PII 剥离。
-- 1. 删除请求追踪表 (不含 PII，只存 ID)
CREATE TABLE deletion_requests (
    request_id VARCHAR(64) PRIMARY KEY,
    user_uuid VARCHAR(64) NOT NULL,    -- 内部系统的 ID，不是 email/phone
    compliance_standard VARCHAR(20),   -- 'GDPR', 'CCPA', 'PIPEDA'
    deadline TIMESTAMP NOT NULL,       -- GDPR 要求 30 天内完成，这里要设 SLA
    status VARCHAR(20) NOT NULL,
    deletion_report_url VARCHAR(255),  -- 存放在 S3/GCS 的详细删除报告链接
    created_at TIMESTAMP,
    finished_at TIMESTAMP
);

-- 2. (可选) 临时 PII 映射表 - 仅用于发通知，任务完成后必须立即物理删除此行
CREATE TABLE deletion_temp_pii (
    request_id VARCHAR(64) PRIMARY KEY,
    encrypted_email VARCHAR(255),      -- 用于最后发通知
    FOREIGN KEY (request_id) REFERENCES deletion_requests(request_id) ON DELETE CASCADE
);

3. Message Payload 设计 (GDPR Context)
Kafka 消息中携带 PII 是危险的（因为 Kafka 有 Retention Policy）。
最佳实践： Message 只传 ID，或者传加密后的 Payload。
A. 入站消息 (Ingress)
compliance_standard 是必须的，因为不同法规的时效要求不同。
{
  "eventId": "evt_12345",
  "payload": {
    "userId": "user_internal_uuid_888",
    "userKeyId": "key_version_1",     // 指向 KMS 中的密钥 ID
    "compliance": "GDPR",
    "requestDate": "2026-02-11T10:00:00Z",
    "slaDeadline": "2026-03-11T10:00:00Z" // 30天后
  }
}

4. 代码逻辑增强 (Java/Spring)
我们需要在原有逻辑中加入 合规检查 和 通知时序控制。
Component: GDPRAwareDeletionConsumer
@Component
@Slf4j
public class GDPRDeletionConsumer {

    @Autowired private DeletionRequestRepository repo;
    @Autowired private TempPIIRepository tempPiiRepo; // 单独的 Repository
    @Autowired private KafkaTemplate<String, String> kafkaTemplate;

    @KafkaListener(topics = "users.deletion.request")
    @Transactional
    public void handleGDPRRequest(ConsumerRecord<String, String> record) {
        GDPRRequestPayload event = parse(record.value());

        // 1. 验证：是否重复？SLA 是否已过？
        if (event.getRequestDate().plusDays(30).isBefore(Instant.now())) {
            log.error("GDPR Violation Risk: Request received after 30 days deadline!");
            // 触发高优先级告警
        }

        // 2. 持久化审计记录 (Audit Trail)
        DeletionRequestEntity entity = new DeletionRequestEntity();
        entity.setUserUuid(event.getUserId());
        entity.setComplianceStandard("GDPR");
        entity.setDeadline(event.getRequestDate().plusDays(30));
        entity.setStatus(Status.PENDING);
        repo.save(entity);

        // 3. 隔离存储 PII (仅为了最后的通知)
        // 这一步很关键：我们不把 email 传给 Airflow，而是暂存在本地
        TempPIIEntity pii = new TempPIIEntity();
        pii.setRequestId(entity.getRequestId());
        pii.setEncryptedEmail(event.getUserEmail()); // 假设上游传了
        tempPiiRepo.save(pii);

        // 4. 发送给 Airflow
        // Payload 不包含 Email，只有 UUID 和需要清理的资源路径
        kafkaTemplate.send("airflow.pipeline.trigger", ...);
    }
}

Component: GDPRCompletionHandler (处理完成逻辑)
GDPR 要求我们必须在删除数据之后通知用户，但如果数据删了，我们去哪找邮箱？
顺序至关重要：
 * Airflow 删除业务数据 (DB, S3, Lake)。
 * Service 收到成功消息。
 * Service 读取 TempPII 表发送 "Goodbye" 邮件。
 * Service 物理删除 TempPII 表中的记录。
 * Service 调用 KMS 销毁 User Key (Crypto-shredding)。
<!-- end list -->
@Component
public class CompletionHandler {

    @KafkaListener(topics = "airflow.pipeline.result")
    @Transactional
    public void onDeletionComplete(AirflowResult result) {
        // 1. 找到请求
        DeletionRequestEntity req = repo.findById(result.getJobId()).get();
        
        if (result.isSuccess()) {
            // 2. 获取临时存储的联系方式
            TempPIIEntity pii = tempPiiRepo.findById(req.getRequestId()).orElse(null);
            
            if (pii != null) {
                // 3. 发送 GDPR 正式通知
                notificationService.send(
                    decrypt(pii.getEncryptedEmail()), 
                    "Your data has been erased in accordance with GDPR."
                );
                
                // 4. 【关键】彻底删除临时 PII
                tempPiiRepo.delete(pii);
            }

            // 5. Crypto-Shredding (最后一步，不可逆)
            // 调用 Key Management Service 删除该用户的密钥
            kmsService.deleteKey(req.getUserUuid());
            
            req.setStatus(Status.COMPLETED);
        } else {
            // GDPR 失败是非常严重的，需要人工介入 (Human inside the loop)
            req.setStatus(Status.MANUAL_REVIEW_REQUIRED);
            alertService.trigger("GDPR Deletion Failed for " + req.getUserUuid());
        }
        
        repo.save(req);
    }
}

5. 必要的补充 (The "Necessary Things")
为了真正符合 GDPR，除了代码，你还需要：
A. Airflow DAG 的报告生成
Airflow 不能只发回 "Success"。它必须生成一份 JSON 或 PDF 报告，列出删除了哪些表、哪些文件。
 * Topic payload update:
   {
  "status": "SUCCESS",
  "report": {
    "db_records_deleted": 142,
    "s3_objects_deleted": 5,
    "archive_paths": ["s3://backups/user_888/"]
  }
}

这份报告作为 Metadata 存起来，万一监管机构（如 ICO）来查，这就是证据。
B. Kafka Compact Topics (Tombstones)
Kafka 里的消息本身也是数据。如果 Kafka 设置了 7 天 retention，那用户数据就在 Kafka 里违规停留了 7 天。
 * Requirement: 配置 Kafka 使用 cleanup.policy=compact。
 * Action: 当用户删除完成后，Service 必须向 Kafka 发送一条 key 为 userId，value 为 null 的消息（即 Tombstone）。这会强制 Kafka 立即移除该 key 之前的所有消息。
C. "Right to Restriction" (冻结)
GDPR 还有一条是“限制处理权”。如果用户还在申诉期，你不能删，也不能用。
 * 你的 Status 需要增加一种：FROZEN。代码中要有逻辑：如果状态是 FROZEN，任何下游 Service (推荐系统、Marketing) 收到该用户的消息都必须丢弃。
总结用户的 GDPR Journey
 * Request: 用户发起。
 * Ack: 系统回复“收到，将在30天内处理”。
 * Shredding: Airflow 清理数据仓库。
 * Proof: 记录清理行数和时间。
 * Notification: 发送“已删除”确认信。
 * The End: 删除临时邮箱记录，销毁加密密钥 (User Key)，发送 Kafka Tombstone。
这个设计体现了你对 Distributed Systems 和 Data Privacy 的双重理解，非常适合在 System Design 面试或实际工作中展示 Senior 水平。
