module "source_bucket-1" {
  source = "./resource_config/source_bucket-1"

  # ... your existing args ...

  # NEW: pass replication inputs down to the child module
  dst_bucket_name            = var.dst_bucket_name
  dst_kms_key_arn            = var.dst_kms_key_arn
  replication_role_name      = var.replication_role_name
  replication_storage_class  = var.replication_storage_class
  enable_batch_replication   = var.enable_batch_replication
  batch_report_prefix        = var.batch_report_prefix
}
