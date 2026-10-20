output "state_bucket_name" {
  description = "Name of the remote state bucket. Put this in terraform/infra/backend.hcl."
  value       = aws_s3_bucket.state.id
}

output "state_bucket_arn" {
  description = "ARN of the remote state bucket."
  value       = aws_s3_bucket.state.arn
}

output "region" {
  description = "Region of the state bucket."
  value       = var.region
}
