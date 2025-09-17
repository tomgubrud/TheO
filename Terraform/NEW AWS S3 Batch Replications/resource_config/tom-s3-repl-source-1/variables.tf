variable "aws_region"               { type = string }
variable "src_bucket_name"          { type = string }
variable "dst_bucket_name"          { type = string }
variable "src_kms_key_arn"          { type = string }
variable "dst_kms_key_arn"          { type = string }
variable "replication_role_name"    { type = string }
variable "replication_storage_class"{ type = string }

variable "enable_batch_job"   { type = bool }
variable "batch_report_prefix"{ type = string }
