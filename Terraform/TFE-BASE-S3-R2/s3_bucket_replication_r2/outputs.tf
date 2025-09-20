output "id" {
  description = "s3 source bucket name the replication configuration is applied to"
  value       = aws_s3_bucket_replication_configuration.replication.id
}

output "role" {
  description = "ARN of the replication role"
  value       = module.aws_iam_role.arn
}

output "sqs" {
  description = "ARN of the SQS queue if it was created"
  value       = try(aws_sqs_queue.queue[0].arn, "")
}
