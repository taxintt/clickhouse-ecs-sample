terraform {
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # backend "s3" {
  #   bucket       = "logplatform-terraform-state"
  #   key          = "terraform.tfstate"
  #   region       = "ap-northeast-1"
  #   use_lockfile = true
  #   encrypt      = true
  # }
}

provider "aws" {
  region  = var.aws_region
  profile = var.aws_profile

  default_tags {
    tags = local.common_tags
  }
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  common_tags = {
    Project         = var.project
    Environment     = var.environment
    ManagedBy       = "terraform"
    TenantIsolation = "logical"
  }

  name_prefix = "${var.project}-${var.environment}"
}
