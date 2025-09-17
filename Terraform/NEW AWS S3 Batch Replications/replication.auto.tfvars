aws_region  = "us-east-2"

src_bucket_name = "dev-sdp-repl-source-1-s3-bucket-ncz"
dst_bucket_name = "dev-sdp-repl-target-1-s3-bucket-ncz"

src_kms_key_arn = "arn:aws:kms:us-east-2:667498787227:key/eeec8666-2e75-4fcb-bd47-4679f5efd86e"
dst_kms_key_arn = "arn:aws:kms:us-east-2:667498787227:key/5e993052-1ea2-4c6f-9357-276c57ad1f5a"

replication_role_name     = "s3-replication-role-tom-test"
replication_storage_class = "STANDARD"
batch_report_prefix       = "batch-replication-reports/"

# flip true only when you want to run the backfill job
enable_batch_job = false
