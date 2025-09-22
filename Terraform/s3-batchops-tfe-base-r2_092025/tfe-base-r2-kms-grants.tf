#################################################
# KMS grants for the replication IAM role (safe)
#################################################

# Source bucket KMS: allow read-side decryption  (and re-encrypt)
resource "aws_kms_grant" "replication_src" {
  name              = "${local.app_code}-${local.env_number}-repl-src"
  key_id            = module.tfe-base-r2-source-2.kms_key_arn
  grantee_principal = module.tfe-base-r2-replication-2.role    # module output = role ARN
  operations        = [
    "Decrypt", "Encrypt", "ReEncryptFrom", "ReEncryptTo",
    "GenerateDataKey", "DescribeKey"
  ]
}

# Destination bucket KMS: allow write-side crypto
resource "aws_kms_grant" "replication_dst" {
  name              = "${local.app_code}-${local.env_number}-repl-dst"
  key_id            = module.tfe-base-r2-target-2.kms_key_arn
  grantee_principal = module.tfe-base-r2-replication-2.role
  operations        = [
    "Encrypt", "ReEncryptFrom", "ReEncryptTo",
    "GenerateDataKey", "DescribeKey"
  ]
}
