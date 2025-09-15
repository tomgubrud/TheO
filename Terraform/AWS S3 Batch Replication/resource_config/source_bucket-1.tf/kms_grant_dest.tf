# Give the replication role permission to encrypt at the DESTINATION KMS key (same account).
resource "aws_kms_grant" "dst_encrypt_for_replication" {
  name              = "s3-repl-${local.src_bucket_name}-to-${var.dst_bucket_name}"
  key_id            = var.dst_kms_key_arn
  grantee_principal = aws_iam_role.replication.arn

  operations = [
    "Encrypt",
    "GenerateDataKey",
    "GenerateDataKeyWithoutPlaintext",
    "ReEncryptFrom",
    "ReEncryptTo"
  ]
}
