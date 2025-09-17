resource "aws_s3_bucket_replication_configuration" "this" {
  bucket = local.src_bucket_name
  role   = aws_iam_role.replication.arn

  rule {
    id     = "default"
    status = "Enabled"

    filter {}

    destination {
      bucket        = local.dst_bucket_arn
      storage_class = var.replication_storage_class

      encryption_configuration {
        replica_kms_key_id = var.dst_kms_key_arn
      }
    }

    # replicate everything (no filter block)

    delete_marker_replication {
      status = "Disabled"
    }

    source_selection_criteria {
      sse_kms_encrypted_objects {
        status = "Enabled"
      }
    }
  }
}
