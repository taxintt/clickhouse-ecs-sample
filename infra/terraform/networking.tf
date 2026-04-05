################################################################################
# VPC (terraform-aws-modules/vpc)
################################################################################

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "${local.name_prefix}-vpc"
  cidr = var.vpc_cidr
  azs  = var.availability_zones

  public_subnets  = [for i, _ in var.availability_zones : cidrsubnet(var.vpc_cidr, 8, i)]
  private_subnets = [for i, _ in var.availability_zones : cidrsubnet(var.vpc_cidr, 8, i + 100)]

  enable_nat_gateway = true
  single_nat_gateway = true

  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = local.common_tags
}

################################################################################
# VPC Endpoints
################################################################################

module "vpc_endpoints" {
  source  = "terraform-aws-modules/vpc/aws//modules/vpc-endpoints"
  version = "~> 5.0"

  vpc_id = module.vpc.vpc_id

  endpoints = {
    s3 = {
      service         = "s3"
      service_type    = "Gateway"
      route_table_ids = module.vpc.private_route_table_ids
      tags            = { Name = "${local.name_prefix}-s3-endpoint" }
    }
  }

  tags = local.common_tags
}

################################################################################
# Security Groups
################################################################################

resource "aws_security_group" "clickhouse" {
  name_prefix = "${local.name_prefix}-clickhouse-"
  description = "Security group for ClickHouse nodes"
  vpc_id      = module.vpc.vpc_id
  tags        = { Name = "${local.name_prefix}-clickhouse-sg" }

  lifecycle { create_before_destroy = true }
}

resource "aws_security_group" "keeper" {
  name_prefix = "${local.name_prefix}-keeper-"
  description = "Security group for ClickHouse Keeper nodes"
  vpc_id      = module.vpc.vpc_id
  tags        = { Name = "${local.name_prefix}-keeper-sg" }

  lifecycle { create_before_destroy = true }
}

resource "aws_security_group" "alb" {
  name_prefix = "${local.name_prefix}-alb-"
  description = "Security group for Application Load Balancer"
  vpc_id      = module.vpc.vpc_id
  tags        = { Name = "${local.name_prefix}-alb-sg" }

  lifecycle { create_before_destroy = true }
}

# --- ClickHouse SG rules ---

resource "aws_vpc_security_group_ingress_rule" "ch_http_from_alb" {
  security_group_id            = aws_security_group.clickhouse.id
  description                  = "HTTP API from ALB"
  from_port                    = 8123
  to_port                      = 8123
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.alb.id
}

resource "aws_vpc_security_group_ingress_rule" "ch_http_self" {
  security_group_id            = aws_security_group.clickhouse.id
  description                  = "HTTP API between nodes"
  from_port                    = 8123
  to_port                      = 8123
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.clickhouse.id
}

resource "aws_vpc_security_group_ingress_rule" "ch_native_vpc" {
  security_group_id = aws_security_group.clickhouse.id
  description       = "Native protocol from VPC"
  from_port         = 9000
  to_port           = 9000
  ip_protocol       = "tcp"
  cidr_ipv4         = var.vpc_cidr
}

resource "aws_vpc_security_group_ingress_rule" "ch_native_self" {
  security_group_id            = aws_security_group.clickhouse.id
  description                  = "Native protocol between nodes"
  from_port                    = 9000
  to_port                      = 9000
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.clickhouse.id
}

resource "aws_vpc_security_group_ingress_rule" "ch_interserver" {
  security_group_id            = aws_security_group.clickhouse.id
  description                  = "Interserver replication"
  from_port                    = 9009
  to_port                      = 9009
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.clickhouse.id
}

resource "aws_vpc_security_group_ingress_rule" "ch_metrics" {
  security_group_id = aws_security_group.clickhouse.id
  description       = "Prometheus metrics"
  from_port         = 9363
  to_port           = 9363
  ip_protocol       = "tcp"
  cidr_ipv4         = var.vpc_cidr
}

resource "aws_vpc_security_group_egress_rule" "ch_all" {
  security_group_id = aws_security_group.clickhouse.id
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

# --- Keeper SG rules ---

resource "aws_vpc_security_group_ingress_rule" "keeper_from_ch" {
  security_group_id            = aws_security_group.keeper.id
  description                  = "Keeper client from ClickHouse"
  from_port                    = 9181
  to_port                      = 9181
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.clickhouse.id
}

resource "aws_vpc_security_group_ingress_rule" "keeper_self" {
  security_group_id            = aws_security_group.keeper.id
  description                  = "Keeper client between nodes"
  from_port                    = 9181
  to_port                      = 9181
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.keeper.id
}

resource "aws_vpc_security_group_ingress_rule" "keeper_raft" {
  security_group_id            = aws_security_group.keeper.id
  description                  = "Keeper Raft consensus"
  from_port                    = 9234
  to_port                      = 9234
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.keeper.id
}

resource "aws_vpc_security_group_egress_rule" "keeper_all" {
  security_group_id = aws_security_group.keeper.id
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

# --- ALB SG rules ---

resource "aws_vpc_security_group_ingress_rule" "alb_http" {
  security_group_id = aws_security_group.alb.id
  description       = "HTTP from VPC"
  from_port         = 80
  to_port           = 80
  ip_protocol       = "tcp"
  cidr_ipv4         = var.vpc_cidr
}

resource "aws_vpc_security_group_egress_rule" "alb_all" {
  security_group_id = aws_security_group.alb.id
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

################################################################################
# CloudShell VPC Security Group
################################################################################

resource "aws_security_group" "cloudshell" {
  name_prefix = "${local.name_prefix}-cloudshell-"
  description = "Security group for CloudShell VPC environment"
  vpc_id      = module.vpc.vpc_id
  tags        = { Name = "${local.name_prefix}-cloudshell-sg" }

  lifecycle { create_before_destroy = true }
}

resource "aws_vpc_security_group_egress_rule" "cloudshell_all" {
  security_group_id = aws_security_group.cloudshell.id
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

# Allow CloudShell to access ClickHouse HTTP API
resource "aws_vpc_security_group_ingress_rule" "ch_http_from_cloudshell" {
  security_group_id            = aws_security_group.clickhouse.id
  description                  = "HTTP API from CloudShell"
  from_port                    = 8123
  to_port                      = 8123
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.cloudshell.id
}

# Allow CloudShell to access ClickHouse native protocol
resource "aws_vpc_security_group_ingress_rule" "ch_native_from_cloudshell" {
  security_group_id            = aws_security_group.clickhouse.id
  description                  = "Native protocol from CloudShell"
  from_port                    = 9000
  to_port                      = 9000
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.cloudshell.id
}

