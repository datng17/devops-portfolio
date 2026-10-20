provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project     = var.project
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  }
}

data "aws_caller_identity" "current" {}

# Infra outputs (VPC, cluster, IRSA roles, log group).
data "terraform_remote_state" "infra" {
  backend = "s3"
  config = {
    bucket = coalesce(var.state_bucket, "${var.project}-tfstate-${data.aws_caller_identity.current.account_id}-${var.region}")
    key    = var.infra_state_key
    region = var.region
  }
}

locals {
  infra = data.terraform_remote_state.infra.outputs

  # Short-lived token from 'aws eks get-token' (AWS CLI v2) on every call,
  # so nothing long-lived is stored in state or kubeconfig.
  cluster_exec = {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = var.aws_cli_command
    args        = ["eks", "get-token", "--region", var.region, "--cluster-name", local.infra.cluster_name, "--output", "json"]
  }
}

# No kubernetes_* resources yet (k8s/platform is applied with kubectl -k);
# configured so platform-level objects can move here without auth changes.
provider "kubernetes" {
  host                   = local.infra.cluster_endpoint
  cluster_ca_certificate = base64decode(local.infra.cluster_certificate_authority_data)

  exec {
    api_version = local.cluster_exec.api_version
    command     = local.cluster_exec.command
    args        = local.cluster_exec.args
  }
}

provider "helm" {
  kubernetes = {
    host                   = local.infra.cluster_endpoint
    cluster_ca_certificate = base64decode(local.infra.cluster_certificate_authority_data)
    exec                   = local.cluster_exec
  }
}
