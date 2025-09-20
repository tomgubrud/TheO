variable "env_number" {
  description = "A number representing the instance/environment of the application to which the instance belongs. Valid range is 1 - 99."
  type        = number
}

variable "app_code" {
  description = "An alphanumeric code representing the application to which the instance belongs. 2 – 3 characters."
  type        = string
}

variable "source_bucket_arn" {
  description = "ARN of the SOURCE bucket (the bucket that already holds the objects)."
  type        = string
}

variable "destination_bucket_arn" {
  description = "ARN of the DESTINATION bucket (objects will be replicated here)."
  type        = string
}

variable "report_bucket_arn" {
  description = "Where the batch job writes its manifest & report. Defaults to the DESTINATION bucket."
  type        = string
  default     = null
}

variable "job_priority" {
  description = "Batch Operations job priority (0–2,147,483,647; higher runs earlier)."
  type        = number
  default     = 10
}

variable "create_job" {
  description = "If false, we only create the role/policy but do not start the batch job."
  type        = bool
  default     = true
}

# Advanced – you normally won’t need to change these.
variable "manifest_prefix" {
  description = "Prefix for generated manifests."
  type        = string
  default     = "batch-replication/manifests/"
}

variable "report_prefix" {
  description = "Prefix for generated reports."
  type        = string
  default     = "batch-replication/reports/"
}
