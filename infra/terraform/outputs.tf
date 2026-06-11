output "vpc_id" {
  value = module.vpc.vpc_id
}

output "private_subnet_ids" {
  value = module.vpc.private_subnets
}

output "ecs_cluster_name" {
  value = aws_ecs_cluster.main.name
}

output "ecr_repository_urls" {
  value = { for k, v in aws_ecr_repository.repos : k => v.repository_url }
}

output "s3_data_bucket_name" {
  value = aws_s3_bucket.data.id
}

output "s3_data_bucket_endpoint" {
  value = local.s3_endpoint
}

output "kinesis_stream_name" {
  value = aws_kinesis_stream.logs.name
}

output "nlb_dns_name" {
  description = "NLB DNS name (HTTP API: port 80, Native Protocol: port 9000)"
  value       = aws_lb.nlb.dns_name
}

output "clickhouse_native_endpoint" {
  description = "ClickHouse native protocol endpoint (port 9000)"
  value       = "${aws_lb.nlb.dns_name}:9000"
}

output "cloudshell_security_group_id" {
  description = "Security group ID for CloudShell VPC environment"
  value       = aws_security_group.cloudshell.id
}

output "clickhouse_fqdns" {
  description = "ClickHouse Service Discovery FQDNs"
  value       = local.ch_fqdns
}

output "keeper_fqdns" {
  description = "Keeper Service Discovery FQDNs"
  value       = local.keeper_fqdns
}
