resource "aws_service_discovery_private_dns_namespace" "main" {
  name        = "${var.project}.local"
  description = "Service discovery for ${local.name_prefix}"
  vpc         = module.vpc.vpc_id
}
