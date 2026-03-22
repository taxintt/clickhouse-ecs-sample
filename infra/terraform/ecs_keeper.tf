################################################################################
# Keeper - CloudWatch Log Group
################################################################################

resource "aws_cloudwatch_log_group" "keeper" {
  name              = "/ecs/${local.name_prefix}/keeper"
  retention_in_days = 30
}

################################################################################
# Keeper - Locals
################################################################################

locals {
  keeper_nodes = { "1" = {}, "2" = {}, "3" = {} }

  keeper_fqdns = {
    "1" = "keeper-1.${var.project}.local"
    "2" = "keeper-2.${var.project}.local"
    "3" = "keeper-3.${var.project}.local"
  }
}

################################################################################
# Keeper - Task Definitions
################################################################################

resource "aws_ecs_task_definition" "keeper" {
  for_each = local.keeper_nodes

  family                   = "${local.name_prefix}-keeper-${each.key}"
  requires_compatibilities = ["EC2"]
  network_mode             = "awsvpc"
  cpu                      = var.keeper_cpu
  memory                   = var.keeper_memory
  execution_role_arn       = aws_iam_role.ecs_task_execution.arn
  task_role_arn            = aws_iam_role.ecs_task_keeper.arn

  container_definitions = jsonencode([{
    name      = "keeper"
    image     = "${aws_ecr_repository.repos["clickhouse-keeper"].repository_url}:latest"
    essential = true

    portMappings = [
      { containerPort = 9181, protocol = "tcp" },
      { containerPort = 9234, protocol = "tcp" },
    ]

    environment = [
      { name = "KEEPER_SERVER_ID", value = each.key },
      { name = "KEEPER_HOST_1", value = local.keeper_fqdns["1"] },
      { name = "KEEPER_HOST_2", value = local.keeper_fqdns["2"] },
      { name = "KEEPER_HOST_3", value = local.keeper_fqdns["3"] },
    ]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.keeper.name
        "awslogs-region"        = data.aws_region.current.name
        "awslogs-stream-prefix" = "keeper-${each.key}"
      }
    }

    healthCheck = {
      command     = ["CMD-SHELL", "echo ruok | nc localhost 9181 | grep -q imok"]
      interval    = 10
      timeout     = 5
      retries     = 3
      startPeriod = 30
    }
  }])
}

################################################################################
# Keeper - Service Discovery
################################################################################

resource "aws_service_discovery_service" "keeper" {
  for_each = local.keeper_nodes

  name = "keeper-${each.key}"

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
# Keeper - ECS Services
################################################################################

resource "aws_ecs_service" "keeper" {
  for_each = local.keeper_nodes

  name            = "${local.name_prefix}-keeper-${each.key}"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.keeper[each.key].arn
  desired_count   = 1

  deployment_minimum_healthy_percent = 0
  deployment_maximum_percent         = 100

  network_configuration {
    subnets         = local.private_subnet_ids
    security_groups = [aws_security_group.keeper.id]
  }

  service_registries {
    registry_arn = aws_service_discovery_service.keeper[each.key].arn
  }

  capacity_provider_strategy {
    capacity_provider = "${local.name_prefix}-keeper-${each.key}"
    weight            = 1
    base              = 1
  }

  placement_constraints {
    type       = "memberOf"
    expression = "attribute:keeper_node == ${each.key}"
  }

  depends_on = [aws_ecs_capacity_provider.keeper, aws_ecs_cluster_capacity_providers.main]
}
