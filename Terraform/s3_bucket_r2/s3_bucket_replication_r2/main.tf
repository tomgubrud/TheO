// *********************** S3 Replication MODULE ***********************

locals {
  # arn:aws:s3:::example-bucket-name -> example-bucket-name
  source_bucket_id_split      = split(":", var.source_bucket_arn)
  source_bucket_id            = local.source_bucket_id_split[length(local.source_bucket_id_split) - 1]

  destination_bucket_id_split = split(":", var.destination_bucket_arn)
  destination_bucket_id       = local.destination_bucket_id_split[length(local.destination_bucket_id_split) - 1]

  replication_id = "${var.app_code}-${var.env_number}-replication"
}

data "aws_caller_identity" "current" {}

# Replication Role
module "aws_iam_role" {
  source          = "git::https://github.crit.theocc.net/platform-engineering-org/tf-modules-base.git//aws/security/iam/role?ref=master"
  name            = local.replication_id
  description     = "IAM role for S3 replication"
  is_third_party  = false
  # IAM to allow s3 to assume this role
  assume_role_policy = <<POLICY
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": { "Service": "s3.amazonaws.com" },
      "Action": "sts:AssumeRole"
    }
  ]
}
POLICY
}

# Policy to allow the replication role required permissions
resource "aws_iam_policy" "replication_policy" {
  name        = "${local.replication_id}-policy"
  description = "S3 Replication Policy for ${local.replication_id}"
  policy = <<POLICY
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "kms:Decrypt",
        "kms:Encrypt",
        "kms:GenerateDataKey"
      ],
      "Resource": "*"
    },
    {
      "Effect": "Allow",
      "Action": [
        "s3:GetReplicationConfiguration",
        "s3:GetBucketVersioning",
        "s3:ListBucket",
        "s3:GetBucketLocation",
        "s3:ListBucketMultipartUploads"
      ],
      "Resource": ["${var.source_bucket_arn}"]
    },
    {
      "Effect": "Allow",
      "Action": [
        "s3:GetObjectVersionForReplication",
        "s3:GetObjectVersionAcl",
        "s3:GetObjectVersionTagging",
        "s3:GetObjectRetention",
        "s3:GetObjectLegalHold",
        "s3:GetObject",
        "s3:ReplicateTags",
        "s3:GetObjectAttributes"
      ],
      "Resource": ["${var.source_bucket_arn}/*"]
    },
    {
      "Effect": "Allow",
      "Action": [
        "s3:ReplicateObject",
        "s3:ReplicateDelete",
        "s3:ReplicateTags",
        "s3:ObjectOwnerOverrideToBucketOwner",
        "s3:PutObjectAcl",
        "s3:PutObjectVersionAcl",
        "s3:PutObject"
      ],
      "Resource": ["${var.destination_bucket_arn}/*"]
    },
    {
      "Effect": "Allow",
      "Action": [
        "s3:GetBucketVersioning",
        "s3:PutBucketVersioning",
        "s3:ListBucket"
      ],
      "Resource": ["${var.destination_bucket_arn}"]
    }
  ]
}
POLICY
}

resource "aws_iam_role_policy_attachment" "replication-policy-attach" {
  role       = module_aws_iam_role.name
  policy_arn = aws_iam_policy.replication_policy.arn
}

resource "aws_s3_bucket_versioning" "source_versioning" {
  bucket = local.source_bucket_id
  versioning_configuration { status = "Enabled" }
}

# S3 Replication Attachment Configuration
resource "aws_s3_bucket_replication_configuration" "replication" {
  role   = module_aws_iam_role.arn
  bucket = local.source_bucket_id

  dynamic "rule" {
    for_each = flatten(try([var.replication_configuration["rule"]], [var.replication_configuration["rules"]], []))
    content {
      id       = try(rule.value.id, null)
      priority = try(rule.value.priority, null)
      prefix   = try(rule.value.prefix, null)
      status   = try(tobool(rule.value.status) ? "Enabled" : "Disabled", title(lower(rule.value.status)), "Enabled")

      dynamic "delete_marker_replication" {
        for_each = flatten(try([rule.value.delete_marker_replication_status], [rule.value.delete_marker_replication], []))
        content {
          # Valid values: "Enabled" or "Disabled"
          status = try(tobool(delete_marker_replication.value) ? "Enabled" : "Disabled", title(lower(delete_marker_replication.value)), "Disabled")
        }
      }

      # Amazon S3 does not support this argument according to:
      # https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_replication_configuration
      # More info about what does Amazon S3 replicate?
      # https://docs.aws.amazon.com/amazons3/latest/userguide/replication-what-is-isnot-replicated.html
      dynamic "existing_object_replication" {
        for_each = flatten(try([rule.value.existing_object_replication_status], [rule.value.existing_object_replication], []))
        content {
          # Valid values: "Enabled" or "Disabled"
          status = try(tobool(existing_object_replication.value) ? "Enabled" : "Disabled", title(lower(existing_object_replication.value)))
        }
      }

      dynamic "destination" {
        for_each = try(flatten([rule.value.destination]), [])
        content {
          bucket        = destination.value.bucket
          storage_class = try(destination.value.storage_class, null)
          account       = try(destination.value.account_id, destination.value.account, null)

          dynamic "access_control_translation" {
            for_each = try(flatten([destination.value.access_control_translation]), [])
            content { owner = title(lower(access_control_translation.value.owner)) }
          }

          dynamic "encryption_configuration" {
            for_each = flatten(try([destination.value.encryption_configuration.replica_kms_key_id], [destination.value.replica_kms_key_id], []))
            content { replica_kms_key_id = encryption_configuration.value }
          }

          dynamic "replication_time" {
            for_each = try(flatten([destination.value.replication_time]), [])
            content {
              # Valid values: "Enabled" or "Disabled"
              status = try(tobool(replication_time.value.status) ? "Enabled" : "Disabled", title(lower(replication_time.value.status)), "Disabled")
              dynamic "time" {
                for_each = try(flatten([replication_time.value.minutes]), [])
                content { minutes = replication_time.value.minutes }
              }
            }
          }

          dynamic "metrics" {
            for_each = try(flatten([destination.value.metrics]), [])
            content {
              # Valid values: "Enabled" or "Disabled"
              status = try(tobool(metrics.value.status) ? "Enabled" : "Disabled", title(lower(metrics.value.status)), "Disabled")
              dynamic "event_threshold" {
                for_each = try(flatten([metrics.value.minutes]), [])
                content { minutes = metrics.value.minutes }
              }
            }
          }
        }
      }

      dynamic "source_selection_criteria" {
        for_each = try(flatten([rule.value.source_selection_criteria]), [])
        content {
          dynamic "replica_modifications" {
            for_each = flatten(try([source_selection_criteria.value.replica_modifications.enabled, source_selection_criteria.value.replica_modifications.status, []]))
            content {
              # Valid values: "Enabled" or "Disabled"
              status = try(tobool(replica_modifications.value) ? "Enabled" : "Disabled", title(lower(replica_modifications.value)), "Disabled")
            }
          }
          dynamic "sse_kms_encrypted_objects" {
            for_each = flatten(try([source_selection_criteria.value.sse_kms_encrypted_objects.enabled, source_selection_criteria.value.sse_kms_encrypted_objects.status, []]))
            content {
              # Valid values: "Enabled" or "Disabled"
              status = try(tobool(sse_kms_encrypted_objects.value) ? "Enabled" : "Disabled", title(lower(sse_kms_encrypted_objects.value)), "Disabled")
            }
          }
        }
      }

      # Max 1 block - filter - without any key arguments or tags
      dynamic "filter" {
        for_each = length(try(flatten([rule.value.filter]), [])) == 0 ? [true] : []
        content {}
      }

      # Max 1 block - filter - with one key argument or a single tag
      dynamic "filter" {
        for_each = [for v in try(flatten([rule.value.filter]), []) : v if max(length(keys(v)), length(try(rule.value.filter.tags, rule.value.filter.tag, []))) == 1]
        content {
          prefix = try(filter.value.prefix, null)
          dynamic "tag" {
            for_each = try(filter.value.tags, filter.value.tag, [])
            content { 
                key = tag.key
                value = tag.value 
                }
          }
        }
      }

      # Max 1 block - filter - with more than one key arguments or multiple tags
      dynamic "filter" {
        for_each = [for v in try(flatten([rule.value.filter]), []) : v if max(length(keys(v)), length(try(rule.value.filter.tags, rule.value.filter.tag, []))) > 1]
        content {
          and {
            prefix = try(filter.value.prefix, null)
            tags   = try(filter.value.tags, filter.value.tag, null)
          }
        }
      }
    }
  }
}

resource "aws_sqs_queue" "queue" {
  count  = var.create_sqs_event_logging ? 1 : 0
  name   = "${local.replication_id}-event-notification"
  policy = <<POLICY
{
  "Version": "2012-10-17",
  "Id": "${local.replication_id}-event-notification",
  "Statement": [
    {
      "Sid": "${local.replication_id}Allows3SendMessageSQS",
      "Effect": "Allow",
      "Principal": { "Service": "s3.amazonaws.com" },
      "Action": [ "SQS:SendMessage" ],
      "Resource": "arn:aws:sqs:us-east-2:${data.aws_caller_identity.current.account_id}:${local.replication_id}-event-notification",
      "Condition": {
        "ArnLike":     { "aws:SourceArn": "arn:aws:s3:::${local.source_bucket_id}" },
        "StringEquals": { "aws:SourceAccount": "${data.aws_caller_identity.current.account_id}" }
      }
    }
  ]
}
POLICY

  visibility_timeout_seconds = var.sqs_logging_visibility_timeout
}

# S3 Replication Event Notification to SQS
# For all actions related to S3:Replication:*
# Needs to be applied on SOURCE bucket in order to function
resource "aws_s3_bucket_notification" "bucket_notification" {
  count  = var.create_sqs_event_logging ? 1 : 0
  bucket = local.source_bucket_id

  queue {
    queue_arn = aws_sqs_queue.queue[0].arn
    events    = ["s3:Replication:*"]
  }
}
