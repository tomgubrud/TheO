############################################
# S3 Replication (new objects going forward)
############################################
module "tfe-base-r2-replication-2" {
  # Same version pin you used for s3_bucket/kms
  source = "git::https://github.crit.theocc.net/platform-org/tf-modules-base.git//aws/storage/s3_bucket_replication_r2?ref=v14"

  # Standard tags/locals you already have in terraform/locals.tf
  app_code   = local.app_code
  env_number = local.env_number

  # Wire from the two bucket modules’ outputs
  source_bucket_arn              = module.tfe-base-r2-source-2.arn
  source_bucket_kms_key_arn      = module.tfe-base-r2-source-2.kms_key_arn
  destination_bucket_arn         = module.tfe-base-r2-target-2.arn
  destination_bucket_kms_key_arn = module.tfe-base-r2-target-2.kms_key_arn

  # Minimal, all-objects, SSE-KMS-to-SSE-KMS rule
  replication_configuration = {
    rules = {
      all = {
        id       = "replicate-all"
        status   = "Enabled"
        priority = 1

        # replicate everything (no prefix/tag filter)
        filter = {}

        delete_marker_replication_status = "Disabled"

        destination = {
          bucket        = module.tfe-base-r2-target-2.arn
          storage_class = "STANDARD"
          encryption_configuration = {
            replica_kms_key_id = module.tfe-base-r2-target-2.kms_key_arn
          }
        }

        # Your buckets enforce KMS; tell S3 to only pick up SSE-KMS objects
        source_selection_criteria = {
          sse_kms_encrypted_objects = { enabled = true }
        }
      }
    }
  }

  # Off for now (we’ll introduce/enable batch-related bits later)
  create_sqs_event_logging       = false
  sqs_logging_visibility_timeout = 600
}
