variable "dst_bucket_name"   { type = string }   # e.g., "nc-dev-00-aog-data-sdp-s3-integration"
variable "dst_kms_key_arn"   { type = string }   # e.g., "arn:aws:kms:us-east-2:...:key/5e99..."
variable "replication_role_name" { type = string default = "s3-replication-role" }
variable "replication_storage_class" { type = string default = "STANDARD" }
variable "enable_batch_replication" { type = bool   default = true }
variable "batch_report_prefix"      { type = string default = "batch-replication-reports/" }

# use the existing modules to derive SOURCE values
locals {
  src_bucket_name = module.aws_s3_bucket.bucket_name
  src_bucket_arn  = module.aws_s3_bucket.bucket_arn
  src_kms_key_arn = module.aws_s3_kms_key.key_arn

  dst_bucket_arn  = "arn:aws:s3:::${var.dst_bucket_name}"
}
