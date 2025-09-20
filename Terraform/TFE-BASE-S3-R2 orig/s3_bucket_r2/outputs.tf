output "id" {
  description = "ID of the s3 bucket."
  value       = element(concat(aws_s3_bucket.base_bucket.*.id), 0)
}

output "name" {
  description = "Name of the s3 bucket."
  value       = element(concat(aws_s3_bucket.base_bucket.*.id), 0)
}

output "arn" {
  description = "Arn of s3 bucket."
  value       = element(concat(aws_s3_bucket.base_bucket.*.arn), 0)
}
