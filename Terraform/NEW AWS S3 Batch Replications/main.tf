module "tom-s3-repl-source-1" {
  source = "../resource_config/tom-s3-repl-source-1"

  aws_region               = var.aws_region
  src_bucket_name          = var.src_bucket_name
  dst_bucket_name          = var.dst_bucket_name
  src_kms_key_arn          = var.src_kms_key_arn
  dst_kms_key_arn          = var.dst_kms_key_arn
  replication_role_name    = var.replication_role_name
  replication_storage_class= var.replication_storage_class

  enable_batch_job         = var.enable_batch_job
  batch_report_prefix      = var.batch_report_prefix
}

module "tom-s3-repl-target-1" {
  source = "../resource_config/tom-s3-repl-target-1"

  aws_region          = var.aws_region
  dst_bucket_name     = var.dst_bucket_name
  dst_kms_key_arn     = var.dst_kms_key_arn
  replication_role_arn= module.tom-s3-repl-source-1.replication_role_arn
  batch_report_prefix = var.batch_report_prefix
}
