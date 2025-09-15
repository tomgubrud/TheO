variable "enable_batch_replication"  { type = bool   default = true }
variable "batch_report_prefix"       { type = string default = "batch-replication-reports/" }
variable "replication_role_name"     { type = string default = "s3-replication-role" }
variable "dst_bucket_name"           { type = string }
variable "dst_kms_key_arn"           { type = string }
variable "replication_storage_class" { type = string default = "STANDARD" }
