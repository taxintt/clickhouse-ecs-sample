################################################################################
# ECS Cluster
################################################################################

resource "aws_ecs_cluster" "main" {
  name = local.name_prefix

  setting {
    name  = "containerInsights"
    value = "enabled"
  }
}

################################################################################
# AMI
################################################################################

data "aws_ssm_parameter" "ecs_ami_arm64" {
  name = "/aws/service/ecs/optimized-ami/amazon-linux-2023/arm64/recommended/image_id"
}

data "aws_ssm_parameter" "ecs_ami_x86" {
  name = "/aws/service/ecs/optimized-ami/amazon-linux-2023/recommended/image_id"
}

################################################################################
# ClickHouse EC2 (r6gd.4xlarge - ARM64 with NVMe)
################################################################################

locals {
  clickhouse_nodes = {
    "s1r1" = { shard = "01", replica = "clickhouse-shard1-replica1", az_index = 0 }
    "s1r2" = { shard = "01", replica = "clickhouse-shard1-replica2", az_index = 1 }
    "s2r1" = { shard = "02", replica = "clickhouse-shard2-replica1", az_index = 0 }
    "s2r2" = { shard = "02", replica = "clickhouse-shard2-replica2", az_index = 1 }
  }

  private_subnet_ids = module.vpc.private_subnets
}

resource "aws_launch_template" "clickhouse" {
  for_each = local.clickhouse_nodes

  name_prefix   = "${local.name_prefix}-ch-${each.key}-"
  image_id      = data.aws_ssm_parameter.ecs_ami_arm64.value
  instance_type = var.clickhouse_instance_type

  iam_instance_profile {
    name = aws_iam_instance_profile.ec2.name
  }

  vpc_security_group_ids = [aws_security_group.clickhouse.id]

  user_data = base64encode(templatefile("${path.module}/templates/clickhouse_user_data.sh", {
    cluster_name   = aws_ecs_cluster.main.name
    node_attribute = "clickhouse_node"
    node_value     = each.key
  }))

  tag_specifications {
    resource_type = "instance"
    tags = merge(local.common_tags, {
      Name            = "${local.name_prefix}-ch-${each.key}"
      ClickHouseNode  = each.key
      ClickHouseShard = each.value.shard
    })
  }

  lifecycle { create_before_destroy = true }
}

resource "aws_autoscaling_group" "clickhouse" {
  for_each = local.clickhouse_nodes

  name                  = "${local.name_prefix}-ch-${each.key}"
  min_size              = 1
  max_size              = 1
  desired_capacity      = 1
  protect_from_scale_in = true
  vpc_zone_identifier   = [local.private_subnet_ids[each.value.az_index % length(local.private_subnet_ids)]]

  launch_template {
    id      = aws_launch_template.clickhouse[each.key].id
    version = aws_launch_template.clickhouse[each.key].latest_version
  }

  tag {
    key                 = "AmazonECSManaged"
    value               = true
    propagate_at_launch = true
  }

  dynamic "tag" {
    for_each = local.common_tags
    content {
      key                 = tag.key
      value               = tag.value
      propagate_at_launch = true
    }
  }
}

################################################################################
# Keeper EC2 (t3.medium - x86_64)
################################################################################

resource "aws_launch_template" "keeper" {
  for_each = local.keeper_nodes

  name_prefix   = "${local.name_prefix}-keeper-${each.key}-"
  image_id      = data.aws_ssm_parameter.ecs_ami_x86.value
  instance_type = var.keeper_instance_type

  iam_instance_profile {
    name = aws_iam_instance_profile.ec2.name
  }

  vpc_security_group_ids = [aws_security_group.keeper.id]

  user_data = base64encode(templatefile("${path.module}/templates/keeper_user_data.sh", {
    cluster_name   = aws_ecs_cluster.main.name
    node_attribute = "keeper_node"
    node_value     = each.key
    ebs_volume_id  = aws_ebs_volume.keeper[each.key].id
  }))

  tag_specifications {
    resource_type = "instance"
    tags = merge(local.common_tags, {
      Name       = "${local.name_prefix}-keeper-${each.key}"
      KeeperNode = each.key
    })
  }

  lifecycle { create_before_destroy = true }
}

resource "aws_ebs_volume" "keeper" {
  for_each = local.keeper_nodes

  availability_zone = var.availability_zones[index(keys(local.keeper_nodes), each.key) % length(var.availability_zones)]
  size              = 20
  type              = "gp3"
  iops              = 3000
  throughput        = 125
  encrypted         = true

  tags = merge(local.common_tags, {
    Name       = "${local.name_prefix}-keeper-${each.key}-data"
    KeeperNode = each.key
  })

  # lifecycle { prevent_destroy = true }
}

resource "aws_autoscaling_group" "keeper" {
  for_each = local.keeper_nodes

  name                  = "${local.name_prefix}-keeper-${each.key}"
  min_size              = 1
  max_size              = 1
  desired_capacity      = 1
  protect_from_scale_in = true
  vpc_zone_identifier   = [local.private_subnet_ids[index(keys(local.keeper_nodes), each.key) % length(local.private_subnet_ids)]]

  launch_template {
    id      = aws_launch_template.keeper[each.key].id
    version = aws_launch_template.keeper[each.key].latest_version
  }

  tag {
    key                 = "AmazonECSManaged"
    value               = true
    propagate_at_launch = true
  }

  dynamic "tag" {
    for_each = local.common_tags
    content {
      key                 = tag.key
      value               = tag.value
      propagate_at_launch = true
    }
  }
}

################################################################################
# Capacity Providers
################################################################################

resource "aws_ecs_capacity_provider" "clickhouse" {
  for_each = local.clickhouse_nodes

  name = "${local.name_prefix}-ch-${each.key}"

  auto_scaling_group_provider {
    auto_scaling_group_arn         = aws_autoscaling_group.clickhouse[each.key].arn
    managed_termination_protection = "ENABLED"

    managed_scaling {
      status          = "ENABLED"
      target_capacity = 100
    }
  }
}

resource "aws_ecs_capacity_provider" "keeper" {
  for_each = local.keeper_nodes

  name = "${local.name_prefix}-keeper-${each.key}"

  auto_scaling_group_provider {
    auto_scaling_group_arn         = aws_autoscaling_group.keeper[each.key].arn
    managed_termination_protection = "ENABLED"

    managed_scaling {
      status          = "ENABLED"
      target_capacity = 100
    }
  }
}

resource "aws_ecs_cluster_capacity_providers" "main" {
  cluster_name = aws_ecs_cluster.main.name

  capacity_providers = concat(
    [for k, v in aws_ecs_capacity_provider.clickhouse : v.name],
    [for v in aws_ecs_capacity_provider.keeper : v.name],
  )
}
