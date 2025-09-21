locals {
}

resource "aws_s3_bucket" "base_bucket" {
  bucket              = var.bucket_name
  # normally true to allow non-empty buckets to be destroyed
  force_destroy       = var.force_destroy
  object_lock_enabled = var.object_lock_enabled

  tags = merge({ ApplicationID = var.app_code, EnvironmentNumber = var.env_number },
    var.cost_tracking_tags,
    var.additional_tags, substr(var.bucket_name, 0, 3) == "dnd" ? {
      "dnd" = "true"
    } : {})
}

resource "aws_s3_bucket_policy" "base_bucket_policy" {
  bucket = aws_s3_bucket.base_bucket.id
  # Adding a depends on fro lifecycle configs
  # As it helps with CARE assessing bucket deployments
  depends_on = [ aws_s3_bucket_lifecycle_configuration.base_bucket ]
  policy     = var.force_destroy ? data.aws_iam_policy_document.bucket_policy_no_deletion.json : data.aws_iam_policy_document.bucket_policy.json
}

# OCC Policy for mandatory KMS keys on buckets
resource "aws_s3_bucket_server_side_encryption_configuration" "base_bucket" {
  bucket = aws_s3_bucket.base_bucket.id

  rule {
    apply_server_side_encryption_by_default {
      kms_master_key_id = var.kms_key_arn
      sse_algorithm     = "aws:kms"
    }
  }
}

resource "aws_s3_bucket_versioning" "base_bucket" {
  count  = var.create_bucket_versioning ? 1 : 0
  bucket = aws_s3_bucket.base_bucket.id

  versioning_configuration {
    status = var.bucket_versioning_status
  }
}

resource "aws_s3_bucket_object_lock_configuration" "base_bucket" {
  count = var.object_lock_enabled ? 1 : 0

  bucket = aws_s3_bucket.base_bucket.id

  rule {
    default_retention {
      mode = "COMPLIANCE"
      days = var.object_lock_days
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "base_bucket" {
  count  = length(var.lifecycle_rules) > 0 ? 1 : 0
  bucket = aws_s3_bucket.base_bucket.id

  dynamic "rule" {
    for_each = var.lifecycle_rules

    content {
      id     = try(rule.value.id, null)
      status = try(rule.value.enabled ? "Enabled" : "Disabled", tobool(rule.value.status) ? "Enabled" : "Disabled", title(lower(rule.value.status)))

      # Max 1 block - abort_incomplete_multipart_upload
      dynamic "abort_incomplete_multipart_upload" {
        for_each = try([rule.value.abort_incomplete_multipart_upload_days], [])

        content {
          days_after_initiation = try(rule.value.abort_incomplete_multipart_upload_days, null)
        }
      }

      # Max 1 block - expiration
      dynamic "expiration" {
        for_each = try(flatten([rule.value.expiration]), [])

        content {
          date                         = try(expiration.value.date, null)
          days                         = try(expiration.value.days, null)
          expired_object_delete_marker = try(expiration.value.expired_object_delete_marker, null)
        }
      }

      # several blocks - transition
      dynamic "transition" {
        for_each = try(flatten([rule.value.transition]), [])

        content {
          date          = try(transition.value.date, null)
          days          = try(transition.value.days, null)
          storage_class = transition.value.storage_class
        }
      }

      # Max 1 block - noncurrent_version_expiration
      dynamic "noncurrent_version_expiration" {
        for_each = try(flatten([rule.value.noncurrent_version_expiration]), [])

        content {
          newer_noncurrent_versions = try(noncurrent_version_expiration.value.newer_noncurrent_versions, null)
          noncurrent_days           = try(noncurrent_version_expiration.value.days, noncurrent_version_expiration.value.noncurrent_days, null)
        }
      }

      # several blocks - noncurrent_version_transition
      dynamic "noncurrent_version_transition" {
        for_each = try(flatten([rule.value.noncurrent_version_transition]), [])

        content {
          newer_noncurrent_versions = try(noncurrent_version_transition.value.newer_noncurrent_versions, null)
          noncurrent_days           = try(noncurrent_version_transition.value.days, noncurrent_version_transition.value.noncurrent_days, null)
          storage_class             = noncurrent_version_transition.value.storage_class
        }
      }

      # Max 1 block - filter - without any key arguments or tags
      dynamic "filter" {
        for_each = length(try(flatten([rule.value.filter]), [])) == 0 ? [true] : []

        content {
          # prefix = ""
        }
      }

      # Max 1 block - filter - with one key argument or a single tag
      dynamic "filter" {
        for_each = [ for v in try(flatten([rule.value.filter]), []) : v if max(length(keys(v)), length(try(rule.value.filter.tags, rule.value.filter.tag, []))) == 1 ]

        content {
          object_size_greater_than = try(filter.value.object_size_greater_than, null)
          object_size_less_than    = try(filter.value.object_size_less_than, null)
          prefix                   = try(filter.value.prefix, null)

          dynamic "tag" {
            for_each = try(filter.value.tags, filter.value.tag, [])

            content {
              key   = tag.key
              value = tag.value
            }
          }
        }
      }

      # Max 1 block - filter - with more than one key arguments or multiple tags
      dynamic "filter" {
        for_each = [ for v in try(flatten([rule.value.filter]), []) : v if max(length(keys(v)), length(try(rule.value.filter.tags, rule.value.filter.tag, []))) > 1 ]

        content {
          and {
            object_size_greater_than = try(filter.value.object_size_greater_than, null)
            object_size_less_than    = try(filter.value.object_size_less_than, null)
            prefix                   = try(filter.value.prefix, null)
            tags                     = try(filter.value.tags, filter.value.tag, null)
          }
        }
      }
    }
  }

  # Must have bucket versioning enabled first
  depends_on = [aws_s3_bucket_versioning.base_bucket]
}

resource "aws_s3_bucket_ownership_controls" "base_bucket" {
  bucket = aws_s3_bucket.base_bucket.id

  rule {
    object_ownership = "ObjectWriter"
  }
}

resource "aws_s3_bucket_acl" "base_bucket" {
  bucket     = aws_s3_bucket.base_bucket.id
  acl        = "private"
  depends_on = [aws_s3_bucket_ownership_controls.base_bucket]
}
