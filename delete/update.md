这是一个非常合理的业务场景变化。从 "Single User Deletion" 变成 "Tenant with Multiple Services Deletion" 意味着我们的原子操作单元变了。
核心变化点：
 * 粒度 (Granularity)： 现在的删除单元不再是 User，而是 Tenant + Service Instance。
 * 并发与竞态 (Concurrency)： 同一个 Tenant 可能并发发起删除 Service A 和 Service B 的请求。我们需要保证这些请求互不干扰，但又要归属于同一个 Tenant 下进行追踪。
 * 最终一致性 (Eventual Consistency)： GDPR 的 "Right to Erasure" 通常指删除整个人/租户。如果租户只是删除了 "Email Service" 但保留了 "Storage Service"，这属于 "Service Provisioning/Deprovisioning" 范畴，只有当所有服务都删除时，才触发真正的 Tenant PII 销毁。
以下是更新后的设计：
1. 消息设计 (Message Protocol)
关于你的问题：TenantID 可以放在 message 里面吗？
回答： 绝对必须放，而且有讲究。
 * Payload: 必须包含 tenantId。
 * Kafka Key: 强烈建议使用 tenantId 作为 Kafka Message Key。
   * 原因： Kafka 保证同一个 Key 的消息会被分发到同一个 Partition。这能确保针对同一个 Tenant 的所有操作（无论删除 Service A 还是 B）都是有序处理的，避免出现“先收到创建请求，后收到删除请求，但乱序执行”的竞态问题。
A. Ingress Message (Topic: tenant.service.deletion.request)
这是上游发来的。注意 serviceId 的引入。
{
  "traceId": "trace-uuid-999",
  "key": "tenant-12345",  // Kafka Partition Key
  "payload": {
    "tenantId": "tenant-12345",
    "serviceType": "cloud-storage", // 具体的服务类型，e.g., S3, Email, DB
    "serviceInstanceId": "srv-abc-001", // 该 tenant 下具体的服务实例 ID
    "requestedBy": "admin-user-uuid",
    "timestamp": "2026-02-11T12:00:00Z",
    "gdprMode": false // 如果是 true，代表由于 GDPR 引起的删除
  }
}

B. Airflow Trigger Message (Topic: airflow.pipeline.trigger)
我们需要告诉 Airflow 具体去删哪个服务的数据。
{
  "jobId": "del_req_555",
  "traceId": "trace-uuid-999",
  "payload": {
    "dag_id": "service_cleanup_dag", // 这是一个通用的 DAG，通过参数区分
    "conf": {
       "tenant_id": "tenant-12345",
       "target_service": "cloud-storage",
       "target_instance": "srv-abc-001", // Airflow 只清理这个实例的数据
       "dry_run": false
    }
  }
}

2. 数据库设计 (Database Schema)
我们需要从追踪 "User" 变成追踪 "Service Request"。建议将表设计为记录级（Log-based），而不是状态级，以支持同一个 Tenant 多次操作。
Key Design Decision: 使用复合唯一索引来防止重复提交。
CREATE TABLE service_deletion_requests (
    request_id VARCHAR(64) PRIMARY KEY,
    tenant_id VARCHAR(64) NOT NULL,
    service_instance_id VARCHAR(64) NOT NULL,
    service_type VARCHAR(50) NOT NULL,
    trace_id VARCHAR(64),
    airflow_job_id VARCHAR(64),
    status VARCHAR(20) NOT NULL,
    retry_count INT DEFAULT 0,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    finished_at TIMESTAMP,
    duration_ms BIGINT,
    failure_reason TEXT
);

/* Comments:
1. request_id: UUID, comes from the Kafka message key or generated internally to track this specific operation.
2. tenant_id: The top-level entity. Used for grouping and reporting.
3. service_instance_id: CRITICAL. This distinguishes between deleting 'Storage-A' vs 'Storage-B'.
4. status: ENUM('PENDING', 'SENT_TO_AIRFLOW', 'COMPLETED', 'FAILED').
5. Indexing: We need a compound index on (tenant_id, service_instance_id) to quickly find active deletions for a specific service.
*/
CREATE INDEX idx_tenant_service ON service_deletion_requests(tenant_id, service_instance_id);

/*
6. Idempotency Constraint: Ensures we don't process the exact same message twice if Kafka redelivers.
*/
CREATE UNIQUE INDEX idx_dedup_request ON service_deletion_requests(request_id);

3. 代码逻辑更新 (Java/Spring)
我们需要处理“部分删除”的逻辑。
Component: ServiceDeletionConsumer
@Component
@Slf4j
public class ServiceDeletionConsumer {

    @Autowired private ServiceDeletionRepository repo;
    @Autowired private KafkaTemplate<String, String> kafkaTemplate;

    // 监听 Tenant 级别的删除 topic
    @KafkaListener(topics = "tenant.service.deletion.request")
    @Transactional
    public void onServiceDeletionRequest(ConsumerRecord<String, String> record) {
        // record.key() 应该是 tenantId
        ServiceDeletionEvent event = parse(record.value());

        String uniqueRequestId = event.getTraceId() + "_" + event.getPayload().getServiceInstanceId();

        // 1. 幂等性检查：检查该 Service Instance 是否正在删除中
        // 如果状态是 PENDING 或 IN_PROGRESS，则忽略
        Optional<ServiceDeletionEntity> existing = repo.findByServiceInstanceIdAndStatusIn(
            event.getPayload().getServiceInstanceId(), 
            List.of(Status.PENDING, Status.IN_PROGRESS)
        );

        if (existing.isPresent()) {
            log.warn("Deletion already in progress for service: {}", event.getPayload().getServiceInstanceId());
            return;
        }

        // 2. 保存请求 Metadata
        ServiceDeletionEntity entity = new ServiceDeletionEntity();
        entity.setRequestId(uniqueRequestId);
        entity.setTenantId(event.getPayload().getTenantId());
        entity.setServiceInstanceId(event.getPayload().getServiceInstanceId());
        entity.setServiceType(event.getPayload().getServiceType());
        entity.setStatus(Status.PENDING);
        repo.save(entity);

        // 3. 构建 Airflow Payload
        // 这里的关键是把粒度精确到 Service Instance
        AirflowTriggerMessage trigger = new AirflowTriggerMessage();
        trigger.setJobId(uniqueRequestId);
        trigger.setPayload(new AirflowConf(
            "generic_service_cleanup", 
            Map.of(
                "tenantId", event.getPayload().getTenantId(),
                "serviceInstanceId", event.getPayload().getServiceInstanceId(), // 关键参数
                "serviceType", event.getPayload().getServiceType()
            )
        ));

        kafkaTemplate.send("airflow.pipeline.trigger", entity.getTenantId(), toJson(trigger));
    }
}

4. 补充的“必要设计” (Necessary Things for Multi-Service)
作为 6 年经验的 SDE，在多服务场景下，你还需要考虑以下架构问题：
A. 资源依赖检查 (Dependency Check)
如果 Tenant 请求删除 "Database Service"，但他的 "App Service" 还在运行并依赖这个 DB，怎么办？
 * 设计： 在发送给 Airflow 之前，Service App 需要调用一个 DependencyService 检查。
 * 逻辑： 如果有依赖，直接标记为 FAILED (Pre-check failure) 并通知 Tenant "Cannot delete DB while App is running"。
B. 最终清理者 (The "Finalizer")
如果一个 Tenant 有 5 个服务，他发起了 5 次删除请求。当最后一个服务被删除成功后，这个 Tenant 本身是否应该被标记为 "Inactive" 或者触发 GDPR 流程？
 * 设计： 在 handleAirflowResult (Consumer) 成功后的逻辑里加入检查：
   // 在更新完当前 service 状态为 COMPLETED 后
int activeServices = serviceInventoryClient.countActiveServices(tenantId);
if (activeServices == 0) {
    // 这是最后一个服务，触发 Tenant 级别的归档或通知
    kafkaTemplate.send("tenant.lifecycle.events", tenantId, "TENANT_EMPTY");
}

C. 隔离性 (Bulkhead Pattern)
如果某一种服务（比如 Hadoop-Cluster）的删除非常慢，导致 Airflow 堵塞，不要影响 Email-Service 的快速删除。
 * 设计： Airflow DAG 应该根据 serviceType 路由到不同的 Queue 或 Worker Group。
 * API Side: 你的 DB 更新逻辑要快，不要被慢速的 I/O 拖累。
总结图示 (Workflow)
graph TD
    Ingress[Ingress / Upstream] -- "Topic: tenant.service.deletion (Key: TenantID)" --> Consumer[Your App Consumer]
    Consumer -- "DB: Insert PENDING (Row per Service)" --> DB[(Metadata DB)]
    Consumer -- "Topic: airflow.trigger" --> Airflow[Airflow DAG]
    
    subgraph Airflow Processing
    Airflow -- "Delete S3 Bucket" --> S3
    Airflow -- "Drop SQL Database" --> RDS
    end
    
    Airflow -- "Topic: airflow.result" --> ResultConsumer[Your App Result Handler]
    ResultConsumer -- "DB: Update Status (COMPLETED)" --> DB
    ResultConsumer -- "Check: Is this the last service?" --> Finalizer{Last Service?}
    Finalizer -- Yes --> TenantCleanup[Trigger Tenant Cleanup]
    Finalizer -- No --> Notify[Notify Service Deletion Only]

