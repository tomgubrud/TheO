module "tom_dst_base_kms_policy" {
  source = "git::https://github.crit.theocc.net/platform-engineering-org/tf-modules-base.git//aws/security/kms/occ_base_kms_key_policy?ref=v14"
}

module "tom_dst_kms_key" {
  source             = "git::https://github.crit.theocc.net/platform-engineering-org/tf-modules-base.git//aws/security/kms/kms_key?ref=v14"
  key_label          = "tom-tfe-base-r2-target-1-kms"
  policy             = module.tom_dst_base_kms_policy.policy
  app_code           = local.app_code
  env_number         = local.env_number
  region             = local.region
  cost_tracking_tags = local.cost_tracking_tags
}

module "tom_target_bucket" {
  source                   = "git::https://github.crit.theocc.net/platform-engineering-org/tf-modules-base.git//aws/storage/s3_bucket_r2?ref=v14"
  bucket_name              = "tom-tfe-base-r2-target-1"
  kms_key_arn              = module.tom_dst_kms_key.key_arn
  create_bucket_versioning = true
  app_code                 = local.app_code
  env_number               = local.env_number
  cost_tracking_tags       = local.cost_tracking_tags
}
