# S3 Bucket KMS Key Policy
module aws_s3_kms_key_policy {
source = "git: :https://github.crit.theocc.net/platform-org/tf-modules-base.git//aws/security/kms/occ_base_kms_key_policy?ref=v14"
}
# S3 Bucket KMS Key
module aws_s3_kms_key {
}
additional_tags
InfraZone
AppZone
CostCenter
KeyLabel
source


policy

= module.aws_s3_kms_key_policy.policy
description

= "s3 KMS key"
key _label

= "s3-repl-source-1"
app_code

= var.app_code
env_number

= var.env_number
region
=
var.region
cost_tracking_tags


Domain

var. cost_tracking_tags.Domain


BusinessDepartment = var.cost_tracking_tags.BusinessDepartment
ZoneGroupID

= var.cost_tracking_tags.ZoneGroupID
EnvironmentType

= var.cost_tracking_tags.EnvironmentType
= "git::https://github.crit.theocc.net/platform-org/tf-modules-base.git//aws/security/kms/kms_key?ref=v14"
= var.infra_zone = var.app_zone
= var.cost_tracking_tags.CostCenter
= var.app_code
# S3 Bucket
module aws_s3_bucket
source
= "git: :https://github.crit.theocc.net/platform-org/tf-modules-base.git//aws/storage/s3_bucket?ref=v14"
bucket_name
= "${var.cost_tracking_tags.EnvironmentType}-${var-app_code)-${local.instance_name}-s3-bucket-ncz"
kms_key_arn
= module-aws_s3_kms_key.key_arn
app_code
= var.app_code
env_number
= var. env_number
versioning
tpue
cost_tracking_tags = var.cost_tracking_tags