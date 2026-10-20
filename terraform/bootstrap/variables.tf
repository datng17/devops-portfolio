variable "region" {
  description = "AWS region for the state bucket."
  type        = string
  default     = "us-east-1"
}

variable "project" {
  description = "Project name used for tagging and the default bucket name."
  type        = string
  default     = "eks-portfolio"
}

variable "environment" {
  description = "Environment tag value."
  type        = string
  default     = "dev"
}

variable "state_bucket_name" {
  description = "Override for the state bucket name. Null derives <project>-tfstate-<account_id>-<region>."
  type        = string
  default     = null
}

variable "noncurrent_version_retention_days" {
  description = "Days to keep non-current state object versions."
  type        = number
  default     = 90
}
