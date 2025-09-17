# Buckets
variable "src_bucket_name" { type = string }
variable "dst_bucket_name" { type = string }

# KMS
variable "src_kms_key_arn" { type = string }
variable "dst_kms_key_arn" { type = string }

# Role / replication details
variable "replication_role_name" {
  type    = string
  default = "s3-replication-role"
}

variable "replication_storage_class" {
  type    = string
  default = "STANDARD"
}

# Batch Ops options
variable "enable_batch_job" {
  description = "Submit one-time backfill via S3 Batch Ops"
  type        = bool
  default     = false
}

variable "batch_report_prefix" {
  description = "Prefix in destination bucket for Batch Ops reports"
  type        = string
  default     = "batch-replication-reports/"
}
