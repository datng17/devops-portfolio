terraform {
  # 1.10+ is required for native S3 state locking (use_lockfile).
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.69"
    }
    # Looks up the current public IP for the EKS API allowlist (admin_ip.tf).
    http = {
      source  = "hashicorp/http"
      version = "~> 3.5"
    }
  }
}
