resource "aws_kinesis_stream" "logs" {
  name             = "${local.name_prefix}-logs"
  shard_count      = var.kinesis_shard_count
  retention_period = 24
  encryption_type  = "KMS"
  kms_key_id       = "alias/aws/kinesis"

  stream_mode_details {
    stream_mode = "PROVISIONED"
  }
}
