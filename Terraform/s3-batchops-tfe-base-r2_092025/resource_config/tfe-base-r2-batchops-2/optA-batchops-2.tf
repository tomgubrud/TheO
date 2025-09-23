#############################################
# S3 Batch Operations (auto-manifest)
#############################################

data "aws_caller_identity" "current" {}

# ----- inputs (same names you already use) -----
variable "app_code"                { type = string }
variable "env_number"              { type = number }
variable "source_bucket_arn"       { type = string }
variable "source_kms_key_arn"      { type = string }
variable "destination_bucket_arn"  { type = string }
variable "destination_kms_key_arn" { type = string }

# Optional job label for uniqueness/readability
variable "purpose"                 { 
  type = string  
  default = "backfill" 
  }

locals {
  batchops_id = "${var.app_code}-${var.env_number}-batchops-${var.purpose}"
  src_objs    = "${var.source_bucket_arn}/*"
  dst_objs    = "${var.destination_bucket_arn}/*"
}

# ----- IAM role for Batch Ops -----
data "aws_iam_policy_document" "assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals { 
      type = "Service" 
      identifiers = ["batchoperations.s3.amazonaws.com"] 
      }
  }
}

resource "aws_iam_role" "batch_ops" {
  name               = substr("${local.batchops_id}-role", 0, 64)
  assume_role_policy = data.aws_iam_policy_document.assume.json
  description        = "S3 Batch Ops role for ${local.batchops_id}"
}

data "aws_iam_policy_document" "policy" {
  statement { # read source objects
    actions   = ["s3:ListBucket"]
    resources = [var.source_bucket_arn]
  }
  statement {
    actions   = ["s3:GetObject","s3:GetObjectVersion"]
    resources = [local.src_objs]
  }
  statement { # decrypt source KMS
    actions   = ["kms:Decrypt"]
    resources = [var.source_kms_key_arn]
  }
  statement { # write destination objects
    actions   = ["s3:ListBucket","s3:GetBucketLocation"]
    resources = [var.destination_bucket_arn]
  }
  statement {
    actions   = ["s3:PutObject","s3:AbortMultipartUpload"]
    resources = [local.dst_objs]
  }
  statement { # encrypt with dest KMS
    actions   = ["kms:Encrypt","kms:ReEncrypt*","kms:GenerateDataKey*","kms:Decrypt"]
    resources = [var.destination_kms_key_arn]
  }
}

resource "aws_iam_policy" "policy" {
  name   = substr("${local.batchops_id}-policy", 0, 128)
  policy = data.aws_iam_policy_document.policy.json
}

resource "aws_iam_role_policy_attachment" "attach" {
  role       = aws_iam_role.batch_ops.name
  policy_arn = aws_iam_policy.policy.arn
}

# ----- S3 Batch Ops job (COPY) with auto-manifest -----
resource "aws_s3control_job" "copy_existing" {
  account_id             = data.aws_caller_identity.current.account_id
  description            = "Backfill ${local.batchops_id} from ${var.source_bucket_arn} to ${var.destination_bucket_arn}"
  priority               = 10
  role_arn               = aws_iam_role.batch_ops.arn
  confirmation_required  = true   # create suspended; you confirm to run

  # Auto-generate manifest from the source bucket (no CSV needed)
  manifest_generator {
    s3_job_manifest_generator {
      expected_bucket_owner = data.aws_caller_identity.current.account_id
      source_bucket         = var.source_bucket_arn

      # Optional filters you can uncomment later:
      # filter {
      #   match_any_prefix = [""]                # or ["logs/","data/"]
      #   created_after    = "2025-01-01T00:00:00Z"
      #   object_size_greater_than = 0
      # }

      enable_manifest_output = true

      manifest_output_location {
        expected_manifest_bucket_owner = data.aws_caller_identity.current.account_id
        bucket  = var.destination_bucket_arn
        prefix  = "batchops/manifests/${local.batchops_id}/"
        manifest_encryption { 
          sse_kms { key_id = var.destination_kms_key_arn } 
          }
        manifest_format = "S3InventoryReport_CSV_20211130"
      }
    }
  }

  operation {
    s3_put_object_copy {
      target_resource     = var.destination_bucket_arn
      metadata_directive  = "COPY"
      storage_class       = "STANDARD"
      sse_kms_encryption { key_id = var.destination_kms_key_arn }
    }
  }

  report {
    bucket       = var.destination_bucket_arn
    prefix       = "batchops/reports/${local.batchops_id}/"
    format       = "Report_CSV_20180820"
    enabled      = true
    report_scope = "AllTasks"
  }
}

output "job_id"   { value = aws_s3control_job.copy_existing.id }
output "role_arn" { value = aws_iam_role.batch_ops.arn }
