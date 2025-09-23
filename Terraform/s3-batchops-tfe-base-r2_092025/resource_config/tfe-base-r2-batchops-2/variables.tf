variable "app_code"            { type = string }
variable "env_number"          { type = number }
variable "region"              { type = string }
variable "purpose"             { type = string, default = "S3 Batch copy of existing objects (initial sync)" }

variable "source_bucket_arn"        { type = string }
variable "destination_bucket_arn"   { type = string }
variable "source_kms_key_arn"       { type = string }
variable "destination_kms_key_arn"  { type = string }

# Optional prefixes written by AWS (no need to pre-create)
variable "manifest_prefix"     { type = string, default = "batch/manifests/" }
variable "report_prefix"       { type = string, default = "batch/reports/" }

variable "job_priority"        { type = number, default = 10 }

# Toggle to actually create/submit the job
variable "enable_batch_copy"   { type = bool,   default = false }
