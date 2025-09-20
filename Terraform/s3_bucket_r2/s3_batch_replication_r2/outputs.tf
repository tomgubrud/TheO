output "role_arn" {
  description = "IAM role used by S3 Batch Operations."
  value       = module.aws_iam_role.arn
}
