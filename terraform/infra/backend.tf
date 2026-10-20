# Partial backend configuration. Bucket, key and region come from
#   terraform init -backend-config=backend.hcl
# See backend.hcl.example.
terraform {
  backend "s3" {
    # Native S3 locking (Terraform >= 1.10) - no DynamoDB lock table needed.
    use_lockfile = true
    encrypt      = true
  }
}
