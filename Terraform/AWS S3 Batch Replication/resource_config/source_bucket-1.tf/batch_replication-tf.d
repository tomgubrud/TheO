data "aws_caller_identity" "acct" {}

resource "aws_s3control_job" "backfill" {
  count       = var.enable_batch_replication ? 1 : 0
  account_id  = data.aws_caller_identity.acct.account_id
  role_arn    = aws_iam_role.replication.arn
  priority    = 10
  description = "Backfill existing objects from ${local.src_bucket_name} to ${var.dst_bucket_name}"

  manifest_generator {
    s3_job_manifest_generator {
      expected_bucket_owner = data.aws_caller_identity.acct.account_id
      source_bucket         = local.src_bucket_arn

      filter {
        object_replication_statuses = ["NONE"]
      }
    }
  }

  operation {
    s3_replicate_object {}
  }

  report {
    bucket       = local.dst_bucket_arn
    format       = "Report_CSV_20180820"
    enabled      = true
    prefix       = var.batch_report_prefix
    report_scope = "AllTasks"
  }

  depends_on = [aws_iam_role_policy_attachment.replication_attach]
}
