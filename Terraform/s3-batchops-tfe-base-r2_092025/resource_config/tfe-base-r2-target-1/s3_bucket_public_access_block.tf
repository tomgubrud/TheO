# SORT CRT00001255 and CRT00001135
# Meets critera of Security Hub findings where newly created s3 buckets could be public, and blocks this ability
resource "aws_s3_bucket_public_access_block" "base_bucket_block_public" {
  bucket                  = var.bucket_name
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true

  depends_on = [
    aws_s3_bucket.base_bucket
  ]
}
