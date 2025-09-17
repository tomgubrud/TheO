# S3 Bucket KMS Key Policy
module aws_s3_kms_key_policy {
source = "git: :https://github.crit.theocc.net/platform-org/tf-modules-base.git//aws/security/kms/occ_base_kms_key_policy?ref=v14"
}
# S3 Bucket KMS Key
module aws_s3_kms_key {
    source    = "git::https://github.crit.theocc.net/platform-org/tf-modules-base.git//aws/security/kms/kms_key?ref=v14"
    policy  = module.aws_s3_kms_key_policy.policy
    description = "s3 KMS key"
    key_label  =  "s3-repl-source-1"
    app_code    = var.app_code
    env_number  =   var.env_number
    region  = var.region
    cost_tracking_tags  = {
        Domain  = var. cost_tracking_tags.Domain
        BusinessDepartment = var.cost_tracking_tags.BusinessDepartment
        ZoneGroupID = var.cost_tracking_tags.ZoneGroupID
        EnvironmentType = var.cost_tracking_tags.EnvironmentType  
    }
    additional_tags = {
        InfraZone   = var.InfraZone
        AppZone =   var.AppZone
        CostCenter  =   var.cost_tracking_tags.CostCenter
        key_label=  var.app_code
        }
}

