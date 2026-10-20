# IRSA roles for in-cluster components. Each trust policy allows
# sts:AssumeRoleWithWebIdentity from the cluster OIDC provider only, with
# StringEquals on <issuer>:sub (namespace:serviceaccount) and
# <issuer>:aud = sts.amazonaws.com (added by the module). Nodes never get
# EBS, ELB or Logs permissions.

locals {
  ebs_csi_service_account  = "kube-system:ebs-csi-controller-sa"
  lbc_service_account      = "kube-system:aws-load-balancer-controller"
  log_sink_service_account = "portfolio:log-sink"
}

# EBS CSI driver controller (dynamic gp3 provisioning for the log-sink PVC).
# Volumes use the AWS-managed aws/ebs key, so no CMK grants are needed.
module "irsa_ebs_csi" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts"
  version = "6.8.2"

  name            = "${local.name}-ebs-csi"
  use_name_prefix = false
  description     = "IRSA role for the EBS CSI driver controller (${local.ebs_csi_service_account})"

  attach_ebs_csi_policy = true

  oidc_providers = {
    this = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = [local.ebs_csi_service_account]
    }
  }
}

# AWS Load Balancer Controller (installed by terraform/platform via Helm).
module "irsa_lbc" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts"
  version = "6.8.2"

  name            = "${local.name}-lbc"
  use_name_prefix = false
  description     = "IRSA role for the AWS Load Balancer Controller (${local.lbc_service_account})"

  attach_load_balancer_controller_policy = true

  oidc_providers = {
    this = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = [local.lbc_service_account]
    }
  }
}

# Nginx access logs forwarded by the log-sink (Fluent Bit) StatefulSet.
resource "aws_cloudwatch_log_group" "portfolio_nginx" {
  name              = "/eks/${var.cluster_name}/portfolio-nginx"
  retention_in_days = var.app_log_retention_days
}

# log-sink: write-only access to the one log group above (inline policy).
module "irsa_log_sink" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts"
  version = "6.8.2"

  name            = "${local.name}-log-sink"
  use_name_prefix = false
  description     = "IRSA role for the log-sink Fluent Bit StatefulSet (${local.log_sink_service_account})"

  create_policy        = false
  create_inline_policy = true
  inline_policy_permissions = {
    PortfolioNginxLogs = {
      actions = [
        "logs:CreateLogStream",
        "logs:DescribeLogStreams",
        "logs:PutLogEvents",
      ]
      resources = [
        aws_cloudwatch_log_group.portfolio_nginx.arn,
        "${aws_cloudwatch_log_group.portfolio_nginx.arn}:log-stream:*",
      ]
    }
  }

  oidc_providers = {
    this = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = [local.log_sink_service_account]
    }
  }
}
