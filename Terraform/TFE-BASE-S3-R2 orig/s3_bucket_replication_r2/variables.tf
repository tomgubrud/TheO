variable "env_number" {
  description = "A number representing the instance/environment of the application to which the instance belongs. Valid range is 1 - 99."
  type        = number
}

variable "app_code" {
  description = "An alphanumeric code representing the application to which the instance belongs. 2 – 3 characters."
  type        = string
}

variable "source_bucket_arn" {
  description = "The arn of the source bucket. Replication will be applied to this as a configuration"
  type        = string
}

variable "source_bucket_kms_key_arn" {
  description = "The arn of KMS key being used on the source bucket"
  type        = string
}

variable "destination_bucket_arn" {
  description = "The arn of the destination bucket. Objects will be replicated here"
  type        = string
}

variable "destination_bucket_kms_key_arn" {
  description = "The arn of KMS key being used on the destination bucket"
  type        = string
}

# This is the hardest part of this module
# Please use this link for reference
# https://github.com/terraform-aws-modules/terraform-aws-s3-bucket/blob/v3.15.1/examples/s3-replication/main.tf#L68
variable "replication_configuration" {
  description = "Map containing cross-region replication configuration."
  type        = any
  default     = {}
}

variable "create_sqs_event_logging" {
  description = "Setting this to true will create an SQS queue attached to the source bucket as an event notification. This is used for debugging replication events"
  type        = bool
  default     = false
}

variable "sqs_logging_visibility_timeout" {
  description = "The visibility timeout for the queue. An integer from 0 to 43200 (12 hours). The default for this attribute is 600"
  type        = number
  default     = 600
}
