module "tfe-base-r2-batchops-2" {
  source = "./resource_config/tfe-base-r2-batchops-2"

  # purpose shows up in job description + job id (e.g., "seed-copy", "backfill-2025-09")
  purpose = "seed-copy"

  # keep the same locals you already use for other modules
  app_code   = local.app_code
  env_number = local.env_number

  # wire from the two bucket modules you already created
  source_bucket_arn        = module.tfe-base-r2-source-2.arn
  source_kms_key_arn       = module.tfe-base-r2-source-2.kms_key_arn
  destination_bucket_arn   = module.tfe-base-r2-target-2.arn
  destination_kms_key_arn  = module.tfe-base-r2-target-2.kms_key_arn

  # off by default; flip to true when you want the batch job created
  enable_batch_copy = false

  # optional knobs (defaults are fine)
  job_priority    = 10
  manifest_prefix = "_batchops/manifests"
  report_prefix   = "_batchops/reports"
}
