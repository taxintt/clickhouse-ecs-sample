variable "project" {
  description = "Project name used for resource naming"
  type        = string
  default     = "logplatform"
}

variable "aws_profile" {
  description = "AWS Profile Name"
  type        = string
}

variable "environment" {
  description = "Environment name (dev, prod)"
  type        = string
}

variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "ap-northeast-1"
}

variable "vpc_cidr" {
  description = "VPC CIDR block"
  type        = string
  default     = "10.0.0.0/16"
}

variable "availability_zones" {
  description = "List of availability zones"
  type        = list(string)
  default     = ["ap-northeast-1a", "ap-northeast-1c", "ap-northeast-1d"]
}

variable "clickhouse_instance_type" {
  description = "EC2 instance type for ClickHouse nodes"
  type        = string
  # default     = "r6gd.4xlarge"
  default     = "r6gd.xlarge"
}

variable "keeper_instance_type" {
  description = "EC2 instance type for Keeper nodes"
  type        = string
  default     = "t3.medium"
}

variable "clickhouse_cpu" {
  description = "CPU units for ClickHouse task"
  type        = number
  # default     = 15360
  default     = 3072
}

variable "clickhouse_memory" {
  description = "Memory (MiB) for ClickHouse task"
  type        = number
  # default     = 122880
  default     = 28672
}

variable "keeper_cpu" {
  description = "CPU units for Keeper task"
  type        = number
  default     = 512
}

variable "keeper_memory" {
  description = "Memory (MiB) for Keeper task"
  type        = number
  default     = 1024
}

variable "kinesis_shard_count" {
  description = "Number of shards for the Kinesis stream"
  type        = number
  default     = 4
}

variable "clickhouse_default_password" {
  description = "Default admin password for ClickHouse"
  type        = string
  sensitive   = true
}

variable "clickhouse_readonly_password" {
  description = "Readonly user password for ClickHouse"
  type        = string
  sensitive   = true
}
