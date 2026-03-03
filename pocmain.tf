# ==========================================
# 1. 基础配置：Provider 和 存储 (S3)
# ==========================================
provider "aws" {
  region = "<需要你修改的变量: 比如 us-east-1>"
}

resource "aws_s3_bucket" "sftp_storage" {
  bucket = "<需要你修改的变量: 比如 my-company-sftp-poc-bucket-12345>"
}

# ==========================================
# 2. Data Blocks: 获取现有的 VPC 和 网络信息
# （完美展示 Data Block "读取已有资源" 的作用）
# ==========================================
# 获取默认 VPC
data "aws_vpc" "default" {
  default = true
}

# 获取该 VPC 下的所有子网
data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

# 获取 IAM 信任策略 (允许 Transfer Family 扮演角色)
data "aws_iam_policy_document" "transfer_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["transfer.amazonaws.com"]
    }
  }
}

# ==========================================
# 3. 权限配置 (IAM Role)
# ==========================================
resource "aws_iam_role" "sftp_role" {
  name               = "sftp-transfer-role-poc"
  assume_role_policy = data.aws_iam_policy_document.transfer_assume_role.json
}

# 赋予该角色读写 S3 的权限
resource "aws_iam_role_policy" "sftp_s3_access" {
  name = "sftp-s3-access-poc"
  role = aws_iam_role.sftp_role.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action   = ["s3:ListBucket", "s3:GetBucketLocation"]
        Effect   = "Allow"
        Resource = aws_s3_bucket.sftp_storage.arn
      },
      {
        Action   = ["s3:PutObject", "s3:GetObject", "s3:DeleteObject", "s3:GetObjectVersion"]
        Effect   = "Allow"
        Resource = "${aws_s3_bucket.sftp_storage.arn}/*"
      }
    ]
  })
}

# ==========================================
# 4. SFTP Server (部署在 VPC 内部)
# ==========================================
resource "aws_transfer_server" "sftp" {
  endpoint_type = "VPC" # 变动：从 PUBLIC 改为 VPC

  endpoint_details {
    vpc_id     = data.aws_vpc.default.id
    subnet_ids = data.aws_subnets.default.ids
    # 如果需要限制访问来源，可以在这里加上 security_group_ids = ["<你的安全组ID>"]
  }

  protocols              = ["SFTP"]
  
  # 如果你的 "Web App" 是指用你自己的后端 API 来做账号密码验证，
  # 请将 SERVICE_MANAGED 改为 API_GATEWAY，并取消下面 url 和 invocation_role 的注释：
  identity_provider_type = "SERVICE_MANAGED" 
  # url                  = "<需要你修改的变量: 你的自定义 Web App API 接口地址>"
  # invocation_role      = "<需要你修改的变量: 允许调用该 API 的 IAM Role ARN>"

  tags = {
    Name = "SFTP-POC-Server-VPC"
  }
}

# （可选）创建一个内部测试用户
resource "aws_transfer_user" "sftp_user" {
  server_id      = aws_transfer_server.sftp.id
  user_name      = "<需要你修改的变量: 比如 testuser>"
  role           = aws_iam_role.sftp_role.arn
  home_directory = "/${aws_s3_bucket.sftp_storage.bucket}" 
}

# ==========================================
# 5. Connector: 用于主动向外部 SFTP 服务器发送文件
# ==========================================
resource "aws_transfer_connector" "sftp_connector" {
  access_role = aws_iam_role.sftp_role.arn
  url         = "sftp://<需要你修改的变量: 外部目标SFTP的URL, 例如 sftp.example.com>"

  sftp_config {
    # 外部服务器的凭证必须存在 AWS Secrets Manager 里
    user_secret_arn   = "<需要你修改的变量: 存放外部服务器账号密码的 Secrets Manager ARN>"
    # 外部服务器的公钥指纹 (用于防止中间人攻击)
    trusted_host_keys = ["<需要你修改的变量: 目标服务器的公钥, 例如 ssh-rsa AAAAB3NzaC1... >"]
  }

  tags = {
    Name = "SFTP-POC-Connector"
  }
}

# ==========================================
# 6. Web App: AWS Transfer Family 官方 Web 门户
# ==========================================
resource "aws_transfer_web_app" "portal" {
  # 注意：AWS 的 Transfer Web App 强依赖 AWS IAM Identity Center (原 SSO)
  identity_provider_details {
    identity_center_config {
      instance_arn = "<需要你修改的变量: 你 AWS 账号中 IAM Identity Center 实例的 ARN>"
      role         = aws_iam_role.sftp_role.arn
    }
  }

  web_app_units {
    provisioned = 1 # POC 阶段分配 1 个并发单元即可
  }

  tags = {
    Name = "SFTP-POC-WebApp"
  }
}

# ==========================================
# 7. Outputs: 部署后打印重要信息
# ==========================================
output "sftp_server_vpc_endpoint_id" {
  value       = aws_transfer_server.sftp.endpoint_details[0].vpc_endpoint_id
  description = "SFTP 服务器在 VPC 内的 Endpoint ID"
}

output "web_app_id" {
  value       = aws_transfer_web_app.portal.web_app_id
  description = "Transfer Web App 的 ID"
}
