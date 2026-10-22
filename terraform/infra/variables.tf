variable "region" {
  description = "AWS region."
  type        = string
  default     = "us-east-1"
}

variable "project" {
  description = "Project name, used for naming and the Project tag."
  type        = string
  default     = "eks-portfolio"
}

variable "environment" {
  description = "Environment name, used for naming and the Environment tag."
  type        = string
  default     = "dev"
}

variable "cluster_name" {
  description = "EKS cluster name. Also used in the kubernetes.io/cluster/<name> subnet tag."
  type        = string
  default     = "eks-portfolio"
}

variable "vpc_cidr" {
  description = "VPC CIDR block. Must be a /16 for the subnet math in locals.tf."
  type        = string
  default     = "10.0.0.0/16"

  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0)) && endswith(var.vpc_cidr, "/16")
    error_message = "vpc_cidr must be a valid /16 CIDR block."
  }
}

variable "azs" {
  description = "Availability zones to spread subnets across (exactly 2)."
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b"]

  validation {
    condition     = length(var.azs) == 2
    error_message = "Exactly 2 availability zones are expected."
  }
}

variable "enable_interface_endpoints" {
  description = "Create the interface VPC endpoints (~$7.30/mo per endpoint per AZ). The S3 gateway endpoint is always on."
  type        = bool
  default     = true
}

variable "interface_endpoint_services" {
  description = "Short AWS service names for interface endpoints (e.g. ecr.api, ecr.dkr, logs, sts)."
  type        = list(string)
  default     = ["ecr.api", "ecr.dkr", "logs"]
}

variable "ecr_repository_name" {
  description = "Name of the ECR repository for the app image."
  type        = string
  default     = "portfolio"
}

variable "ecr_force_delete" {
  description = "Allow terraform destroy to delete the ECR repository even if it still contains images."
  type        = bool
  default     = false
}

variable "domain_name" {
  description = "Public domain served by the ALB. An ISSUED ACM certificate for it must already exist in the region (managed outside Terraform)."
  type        = string
  default     = "test.name.vn"
}

variable "kubernetes_version" {
  description = "EKS Kubernetes version (latest in standard support)."
  type        = string
  default     = "1.37"
}

variable "admin_cidrs" {
  description = "Extra static CIDRs allowed to reach the public EKS API endpoint, on top of the auto-detected IP (see auto_detect_admin_ip)."
  type        = list(string)
  default     = []

  validation {
    condition = alltrue([
      for c in var.admin_cidrs : can(cidrhost(c, 0)) && c != "0.0.0.0/0"
    ])
    error_message = "admin_cidrs must contain only valid CIDRs and must not include 0.0.0.0/0."
  }

  validation {
    condition     = length(var.admin_cidrs) > 0 || var.auto_detect_admin_ip
    error_message = "Set admin_cidrs or enable auto_detect_admin_ip; the EKS public endpoint needs at least one allowed CIDR."
  }
}

variable "auto_detect_admin_ip" {
  description = "Add the public IP of the machine running Terraform (from https://checkip.amazonaws.com) as a /32 to the EKS API allowlist. Local Jenkins egresses from the same IP. scripts/sync-admin-ip.ps1 keeps it current between applies."
  type        = bool
  default     = true
}

variable "admin_principal_arn" {
  description = "IAM user/role ARN granted AmazonEKSClusterAdminPolicy. Null = the identity running Terraform."
  type        = string
  default     = null
}

variable "cluster_log_retention_days" {
  description = "Retention for the EKS control plane log group (/aws/eks/<name>/cluster)."
  type        = number
  default     = 7
}

variable "app_log_retention_days" {
  description = "Retention for the app access log group (/eks/<name>/portfolio-nginx) written by log-sink."
  type        = number
  default     = 7
}
