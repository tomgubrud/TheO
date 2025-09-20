variable "bucket_name" {
  description = "Name of the S3 bucket."
  type        = string
}

variable "policy" {
  description = "A valid bucket policy JSON document. The policy will be combined with OCC's default bucket policy."
  type        = string
  default     = ""
}

variable "create_bucket_versioning" {
  description = "Enables bucket versioning if true."
  type        = bool
  default     = false
}

variable "bucket_versioning_status" {
  description = "Versioning state of the bucket. Valid values: Enabled, Suspended, or Disabled. Disabled should only be used when creating or importing resources that correspond to unversioned S3 buckets."
  type        = string
  default     = "Enabled"
}

variable "force_destroy" {
  description = "Boolean that indicates all objects (including any locked objects) should be deleted from the bucket when the bucket is destroyed so that the bucket can be destroyed without error. If you have important data that needs to persist, set this to false."
  type        = bool
  default     = true
}

variable "env_number" {
  description = "A number representing the instance/environment of the application to which the instance belongs. Valid range is 1 - 99."
  type        = number
}

variable "app_code" {
  description = "An alphanumeric code representing the application to which the instance belongs. 2 - 3 characters."
  type        = string
}

variable "kms_key_arn" {
  description = "ARN of the KMS key for this bucket."
  type        = string
}

variable "cost_tracking_tags" {
  description = "Object with key-value pairs of resource tags for cost tracking"
  type = object({
    Domain              = string
    BusinessDepartment  = string
    ITDepartment        = string
    CostCenter          = string
    ZoneGroupID         = string
    EnvironmentType     = string
  })
}

variable "additional_tags" {
  description = "Additional key-value pairs to include as tags on all resources created in the module."
  type        = map(string)
  default     = {}
}

variable "lifecycle_rules" {
  description = "List of maps containing configuration of object lifecycle management."
  # Example
  # https://github.com/terraform-aws-modules/terraform-aws-s3-bucket/blob/v3.15.1/examples/complete/main.tf#L231C21-L231C21
  # As lifecycle rules are complex, we should avoid sanitizing them here via type.
  type    = any
  default = []
}

# Does not support import on existing buckets
# The process for applying object lock on existing buckets involves AWS Support
# https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_object_lock_configuration
variable "object_lock_enabled" {
  description = "Whether S3 bucket should have an Object Lock configuration enabled."
  type        = bool
  default     = false
}

variable "object_lock_days" {
  # Valid values are 0-2147483647
  description = "Days to retain bucket objects after they are written (zero disables object locking)."
  type        = number
  default     = 0
}
