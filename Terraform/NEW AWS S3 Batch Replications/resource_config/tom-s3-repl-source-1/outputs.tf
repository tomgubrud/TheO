output "replication_role_arn" {
  value       = local.replication_role_arn
  description = "IAM Role ARN used by S3 replication / Batch Ops"
}
