variable "enable_batch_job" {
  description = "If true, submit the S3 Batch Ops backfill job"
  type        = bool
  default     = false
}

variable "aws_region" {
  description = "Region to call the S3 Control API in"
  type        = string
  default     = "us-east-2"
}

variable "src_bucket_name" {
  description = "Source S3 bucket (replication source)"
  type        = string
}

variable "dst_bucket_name" {
  description = "Destination S3 bucket (replication target)"
  type        = string
}

variable "replication_role_name" {
  description = "IAM role used by replication / Batch Ops"
  type        = string
}

variable "batch_report_prefix" {
  description = "Prefix in DEST bucket for Batch Ops reports"
  type        = string
  default     = "batch-replication-reports/"
}
