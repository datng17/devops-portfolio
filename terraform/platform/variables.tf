variable "region" {
  description = "AWS region (must match terraform/infra)."
  type        = string
  default     = "us-east-1"
}

variable "project" {
  description = "Project name, used for the Project tag."
  type        = string
  default     = "eks-portfolio"
}

variable "environment" {
  description = "Environment name, used for the Environment tag."
  type        = string
  default     = "dev"
}

variable "state_bucket" {
  description = "S3 bucket holding the infra state. Null = eks-portfolio-tfstate-<account_id>-<region> (the bootstrap naming)."
  type        = string
  default     = null
}

variable "infra_state_key" {
  description = "State key of the terraform/infra root."
  type        = string
  default     = "infra/terraform.tfstate"
}

variable "aws_cli_command" {
  description = "AWS CLI executable the helm/kubernetes providers exec for 'aws eks get-token'. Use the full v2 path if v1 comes first on PATH."
  type        = string
  default     = "aws"
}

variable "lbc_chart_version" {
  description = "aws-load-balancer-controller Helm chart version (eks-charts)."
  type        = string
  default     = "3.6.0"
}

variable "lbc_replica_count" {
  description = "AWS Load Balancer Controller replicas."
  type        = number
  default     = 2
}

variable "log_sink_config_path" {
  description = "Where to write the generated, gitignored kustomize env file for log-sink."
  type        = string
  default     = null
}
