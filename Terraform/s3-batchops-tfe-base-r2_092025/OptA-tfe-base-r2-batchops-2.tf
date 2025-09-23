module "tfe-base-r2-batchops-2" {
  source = "./resource_config/tfe-base-r2-batchops-2"

  app_code   = local.app_code
  env_number = local.env_number

  source_bucket_arn        = module.tfe-base-r2-source-2.arn
  source_kms_key_arn       = module.tfe-base-r2-source-2.kms_key_arn
  destination_bucket_arn   = module.tfe-base-r2-target-2.arn
  destination_kms_key_arn  = module.tfe-base-r2-target-2.kms_key_arn
}
