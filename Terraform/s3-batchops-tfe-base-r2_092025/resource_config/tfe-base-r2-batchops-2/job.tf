# Create the job only when enabled
resource "aws_s3control_job" "copy_existing" {
  count      = var.enable_batch_ops ? 1 : 0
  account_id = local.acct_id
  role_arn   = module.batchops_role.arn
  priority   = var.priority
  description          = local.job_name
  client_request_token = local.crt

  # Where the task-level report CSV is written
  report {
    bucket       = var.destination_bucket_arn
    format       = "Report_CSV_20180820"
    enabled      = true
    prefix       = var.report_prefix
    report_scope = "AllTasks"
  }

  # Generate the manifest at run-time by listing the source bucket (optionally by prefixes)
  manifest_generator {
    s3_job_manifest_generator {
      source_bucket         = var.source_bucket_arn
      manifest_format       = "S3BatchOperations_CSV_20180820"
      expected_bucket_owner = local.acct_id

      # copy everything unless prefixes are provided
      dynamic "filter" {
        for_each = length(var.prefixes) > 0 ? [1] : []
        content {
          match_any_prefix = var.prefixes
        }
      }
    }
  }

  # The operation itself: Copy to destination with SSE-KMS
  operation {
    s3_put_object_copy {
      target_resource = var.destination_bucket_arn

      metadata_directive             = "COPY"
      canned_access_control_list     = "bucket-owner-full-control"
      object_lock_legal_hold_status  = "NONE"
      object_lock_mode               = "OFF"

      s3_object_encryption {
        encryption_type = "SSE_KMS"
        kms_key_id      = var.destination_kms_key_arn
      }
    }
  }

  # Optional throttling tier; omit or keep as STANDARD unless you know you need BULK
  job_tier = "STANDARD"

  tags = {
    AppCode    = var.app_code
    EnvironmentNumber = tostring(var.env_number)
    Purpose    = var.purpose
  }
}
