variable "purpose" {
  description = "Short purpose tag for the job id/description (e.g., seed-copy)."
  type        = string
}

variable "app_code" {
  description = "2–3 char code for the app."
  type        = string
}

variable "env_number" {
  description = "Numeric environment number (1–99)."
  type        = number
}

variable "source_bucket_arn" {
  type        = string
  description = "ARN of the SOURCE bucket."
}

variable "source_kms_key_arn" {
  type        = string
  description = "ARN of the SOURCE bucket KMS key."
}

variable "destination_bucket_arn" {
  type        = string
  description = "ARN of the DESTINATION bucket."
}

variable "destination_kms_key_arn" {
  type        = string
  description = "ARN of the DESTINATION bucket KMS key."
}

variable "enable_batch_copy" {
  description = "When true, create/run the S3 Batch Operations job."
  type        = bool
  default     = false
}

variable "job_priority" {
  description = "S3 Batch Operations priority (higher runs sooner)."
  type        = number
  default     = 10
}

variable "manifest_prefix" {
  description = "Prefix (in destination bucket) for the auto-generated manifest."
  type        = string
  default     = "_batchops/manifests"
}

variable "report_prefix" {
  description = "Prefix (in destination bucket) for the job reports."
  type        = string
  default     = "_batchops/reports"
}
