################################################################################
# EC2 Instance Role (minimal - ECS agent, SSM, CloudWatch only)
################################################################################

data "aws_iam_policy_document" "ec2_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ec2_instance" {
  name               = "${local.name_prefix}-ec2-instance"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume_role.json
}

resource "aws_iam_instance_profile" "ec2" {
  name = "${local.name_prefix}-ec2-instance-profile"
  role = aws_iam_role.ec2_instance.name
}

resource "aws_iam_role_policy_attachment" "ec2_ecs_agent" {
  role       = aws_iam_role.ec2_instance.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEC2ContainerServiceforEC2Role"
}

resource "aws_iam_role_policy_attachment" "ec2_ssm" {
  role       = aws_iam_role.ec2_instance.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy_attachment" "ec2_cloudwatch_agent" {
  role       = aws_iam_role.ec2_instance.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

################################################################################
# ECS Task Role (S3, CloudWatch, SSM)
# Policies are independent resources for EKS IRSA migration
################################################################################

data "aws_iam_policy_document" "ecs_task_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ecs_task" {
  name               = "${local.name_prefix}-ecs-task"
  assume_role_policy = data.aws_iam_policy_document.ecs_task_assume_role.json
}

# S3 access policy
resource "aws_iam_policy" "clickhouse_s3_access" {
  name   = "${local.name_prefix}-clickhouse-s3-access"
  policy = data.aws_iam_policy_document.clickhouse_s3_access.json
}

data "aws_iam_policy_document" "clickhouse_s3_access" {
  statement {
    sid = "S3DataBucketAccess"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:ListBucket",
      "s3:GetBucketLocation",
    ]
    resources = [
      aws_s3_bucket.data.arn,
      "${aws_s3_bucket.data.arn}/*",
    ]
  }
}

# CloudWatch Logs policy
resource "aws_iam_policy" "clickhouse_cloudwatch" {
  name   = "${local.name_prefix}-clickhouse-cloudwatch"
  policy = data.aws_iam_policy_document.clickhouse_cloudwatch.json
}

data "aws_iam_policy_document" "clickhouse_cloudwatch" {
  statement {
    sid = "CloudWatchLogs"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "logs:DescribeLogStreams",
    ]
    resources = ["arn:aws:logs:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:log-group:/ecs/${local.name_prefix}/*"]
  }
}

# SSM Parameter Store read policy
resource "aws_iam_policy" "clickhouse_ssm_read" {
  name   = "${local.name_prefix}-clickhouse-ssm-read"
  policy = data.aws_iam_policy_document.clickhouse_ssm_read.json
}

data "aws_iam_policy_document" "clickhouse_ssm_read" {
  statement {
    sid = "SSMParameterRead"
    actions = [
      "ssm:GetParameter",
      "ssm:GetParameters",
      "ssm:GetParametersByPath",
    ]
    resources = ["arn:aws:ssm:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:parameter/${var.project}/${var.environment}/*"]
  }
}

resource "aws_iam_role_policy_attachment" "task_s3" {
  role       = aws_iam_role.ecs_task.name
  policy_arn = aws_iam_policy.clickhouse_s3_access.arn
}

resource "aws_iam_role_policy_attachment" "task_cloudwatch" {
  role       = aws_iam_role.ecs_task.name
  policy_arn = aws_iam_policy.clickhouse_cloudwatch.arn
}

resource "aws_iam_role_policy_attachment" "task_ssm" {
  role       = aws_iam_role.ecs_task.name
  policy_arn = aws_iam_policy.clickhouse_ssm_read.arn
}

################################################################################
# ECS Task Role for Keeper (minimal - no S3/SSM needed)
################################################################################

resource "aws_iam_role" "ecs_task_keeper" {
  name               = "${local.name_prefix}-ecs-task-keeper"
  assume_role_policy = data.aws_iam_policy_document.ecs_task_assume_role.json
}

################################################################################
# ECS Task Execution Role (ECR pull, Secrets Manager, CloudWatch)
################################################################################

resource "aws_iam_role" "ecs_task_execution" {
  name               = "${local.name_prefix}-ecs-task-execution"
  assume_role_policy = data.aws_iam_policy_document.ecs_task_assume_role.json
}

resource "aws_iam_role_policy_attachment" "execution_base" {
  role       = aws_iam_role.ecs_task_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_policy" "secrets_manager_read" {
  name   = "${local.name_prefix}-secrets-manager-read"
  policy = data.aws_iam_policy_document.secrets_manager_read.json
}

data "aws_iam_policy_document" "secrets_manager_read" {
  statement {
    sid       = "SecretsManagerRead"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = ["arn:aws:secretsmanager:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:secret:${var.project}/${var.environment}/*"]
  }
  statement {
    sid       = "KMSDecryptForSecrets"
    actions   = ["kms:Decrypt"]
    resources = [aws_kms_key.clickhouse_secrets.arn]
  }
}

resource "aws_iam_role_policy_attachment" "execution_secrets" {
  role       = aws_iam_role.ecs_task_execution.name
  policy_arn = aws_iam_policy.secrets_manager_read.arn
}
