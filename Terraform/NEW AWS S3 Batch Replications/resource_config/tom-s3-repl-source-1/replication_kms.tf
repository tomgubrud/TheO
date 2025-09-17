# Minimal grants for the role (swap to key policy edits if your KMS pattern prefers)
resource "aws_kms_grant" "src_decrypt" {
  name              = "s3-repl-src-decrypt"
  key_id            = var.src_kms_key_arn
  grantee_principal = local.replication_role_arn
  operations        = ["Decrypt", "DescribeKey"]
}

resource "aws_kms_grant" "dst_encrypt" {
  name              = "s3-repl-dst-encrypt"
  key_id            = var.dst_kms_key_arn
  grantee_principal = local.replication_role_arn
  operations        = ["Encrypt", "GenerateDataKey", "DescribeKey"]
}
