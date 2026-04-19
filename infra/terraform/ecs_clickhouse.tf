################################################################################
# ClickHouse - CloudWatch Log Group
################################################################################

resource "aws_cloudwatch_log_group" "clickhouse" {
  name              = "/ecs/${local.name_prefix}/clickhouse"
  retention_in_days = 30
}

################################################################################
# ClickHouse - Secrets Manager
################################################################################

resource "aws_kms_key" "clickhouse_secrets" {
  description         = "KMS key for ClickHouse Secrets Manager"
  enable_key_rotation = true
  policy              = data.aws_iam_policy_document.clickhouse_kms_policy.json
}

data "aws_iam_policy_document" "clickhouse_kms_policy" {
  statement {
    sid    = "AllowRootAdmin"
    effect = "Allow"
    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"]
    }
    actions   = ["kms:*"]
    resources = ["*"]
  }
  statement {
    sid    = "AllowECSTaskExecutionDecrypt"
    effect = "Allow"
    principals {
      type        = "AWS"
      identifiers = [aws_iam_role.ecs_task_execution.arn]
    }
    actions   = ["kms:Decrypt", "kms:DescribeKey"]
    resources = ["*"]
  }
}

resource "aws_kms_alias" "clickhouse_secrets" {
  name          = "alias/${local.name_prefix}-clickhouse-secrets"
  target_key_id = aws_kms_key.clickhouse_secrets.key_id
}

resource "random_string" "suffix" {
  length  = 8
  upper   = false
  special = false
}

resource "aws_secretsmanager_secret" "clickhouse_credentials" {
  name        = "${var.project}/${var.environment}/clickhouse-credentials-${random_string.suffix.result}"
  description = "ClickHouse user credentials"
  kms_key_id  = aws_kms_key.clickhouse_secrets.arn
}

resource "aws_secretsmanager_secret_version" "clickhouse_credentials" {
  secret_id = aws_secretsmanager_secret.clickhouse_credentials.id
  secret_string = jsonencode({
    default_password  = var.clickhouse_default_password
    readonly_password = var.clickhouse_readonly_password
  })
}

################################################################################
# ClickHouse - Locals
################################################################################

locals {
  ch_fqdns = {
    "s1r1" = "clickhouse-shard1-replica1.${var.project}.local"
    "s1r2" = "clickhouse-shard1-replica2.${var.project}.local"
    "s2r1" = "clickhouse-shard2-replica1.${var.project}.local"
    "s2r2" = "clickhouse-shard2-replica2.${var.project}.local"
  }

  s3_endpoint = "https://s3.${var.aws_region}.amazonaws.com/${aws_s3_bucket.data.id}/clickhouse/"
}

################################################################################
# ClickHouse - Task Definitions
################################################################################

resource "aws_ecs_task_definition" "clickhouse" {
  for_each = local.clickhouse_nodes

  family                   = "${local.name_prefix}-ch-${each.key}"
  requires_compatibilities = ["EC2"]
  network_mode             = "awsvpc"
  cpu                      = var.clickhouse_cpu
  memory                   = var.clickhouse_memory
  execution_role_arn       = aws_iam_role.ecs_task_execution.arn
  task_role_arn            = aws_iam_role.ecs_task.arn

  volume {
    name      = "s3cache"
    host_path = "/var/lib/clickhouse/s3cache"
  }

  container_definitions = jsonencode([{
    name      = "clickhouse"
    image     = "${aws_ecr_repository.repos["clickhouse"].repository_url}:${var.clickhouse_image_tag}"
    essential = true

    portMappings = [
      { containerPort = 8123, protocol = "tcp" },
      { containerPort = 9000, protocol = "tcp" },
      { containerPort = 9009, protocol = "tcp" },
      { containerPort = 9363, protocol = "tcp" },
    ]

    mountPoints = [{
      sourceVolume  = "s3cache"
      containerPath = "/var/lib/clickhouse/s3cache"
      readOnly      = false
    }]

    environment = [
      { name = "CH_SHARD", value = each.value.shard },
      { name = "CH_REPLICA", value = each.value.replica },
      { name = "CH_S3_ENDPOINT", value = local.s3_endpoint },
      { name = "CH_SHARD1_REPLICA1_HOST", value = local.ch_fqdns["s1r1"] },
      { name = "CH_SHARD1_REPLICA2_HOST", value = local.ch_fqdns["s1r2"] },
      { name = "CH_SHARD2_REPLICA1_HOST", value = local.ch_fqdns["s2r1"] },
      { name = "CH_SHARD2_REPLICA2_HOST", value = local.ch_fqdns["s2r2"] },
      { name = "CH_KEEPER_HOST_1", value = local.keeper_fqdns["1"] },
      { name = "CH_KEEPER_HOST_2", value = local.keeper_fqdns["2"] },
      { name = "CH_KEEPER_HOST_3", value = local.keeper_fqdns["3"] },
      { name = "CH_ALLOWED_NETWORKS", value = var.vpc_cidr },
    ]

    secrets = [
      {
        name      = "CH_DEFAULT_PASSWORD"
        valueFrom = "${aws_secretsmanager_secret.clickhouse_credentials.arn}:default_password::"
      },
      {
        name      = "CH_READONLY_PASSWORD"
        valueFrom = "${aws_secretsmanager_secret.clickhouse_credentials.arn}:readonly_password::"
      },
    ]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.clickhouse.name
        "awslogs-region"        = data.aws_region.current.name
        "awslogs-stream-prefix" = "ch-${each.key}"
      }
    }

    healthCheck = {
      command     = ["CMD-SHELL", "wget --no-verbose --tries=1 --spider http://localhost:8123/ping || exit 1"]
      interval    = 30
      timeout     = 5
      retries     = 3
      startPeriod = 60
    }
  }])
}

################################################################################
# ClickHouse - Service Discovery
################################################################################

resource "aws_service_discovery_service" "clickhouse" {
  for_each = local.clickhouse_nodes

  name = each.value.replica

  dns_config {
    namespace_id = aws_service_discovery_private_dns_namespace.main.id

    dns_records {
      ttl  = 10
      type = "A"
    }

    routing_policy = "MULTIVALUE"
  }

  health_check_custom_config {
    failure_threshold = 1
  }
}

################################################################################
# ClickHouse - ECS Services
################################################################################

resource "aws_ecs_service" "clickhouse" {
  for_each = local.clickhouse_nodes

  name            = "${local.name_prefix}-ch-${each.key}"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.clickhouse[each.key].arn
  desired_count   = 1

  deployment_minimum_healthy_percent = 0
  deployment_maximum_percent         = 100
  health_check_grace_period_seconds  = 300

  network_configuration {
    subnets         = local.private_subnet_ids
    security_groups = [aws_security_group.clickhouse.id]
  }

  service_registries {
    registry_arn = aws_service_discovery_service.clickhouse[each.key].arn
  }

  capacity_provider_strategy {
    capacity_provider = "${local.name_prefix}-ch-${each.key}"
    weight            = 1
    base              = 1
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.ch_http.arn
    container_name   = "clickhouse"
    container_port   = 8123
  }

  placement_constraints {
    type       = "memberOf"
    expression = "attribute:clickhouse_node == ${each.key}"
  }

  depends_on = [aws_ecs_capacity_provider.clickhouse, aws_ecs_cluster_capacity_providers.main, aws_ecs_service.keeper]
}
