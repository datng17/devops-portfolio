data "aws_caller_identity" "current" {}

# Resolves an assumed-role session ARN to its IAM role ARN, so the default
# admin access entry works for both IAM users and SSO/assumed roles.
data "aws_iam_session_context" "current" {
  arn = data.aws_caller_identity.current.arn
}

locals {
  admin_principal_arn = coalesce(var.admin_principal_arn, data.aws_iam_session_context.current.issuer_arn)
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "21.29.0"

  name               = var.cluster_name
  kubernetes_version = var.kubernetes_version

  # Stay on standard support; extended support bills $0.60/h instead of $0.10/h.
  upgrade_policy = {
    support_type = "STANDARD"
  }

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  # API reachable publicly from admin/Jenkins CIDRs only; nodes use the
  # private endpoint inside the VPC.
  endpoint_public_access       = true
  endpoint_public_access_cidrs = var.admin_cidrs
  endpoint_private_access      = true

  enabled_log_types                      = ["api", "audit", "authenticator"]
  cloudwatch_log_group_retention_in_days = var.cluster_log_retention_days

  enable_irsa = true

  # Access entries only (no aws-auth ConfigMap).
  authentication_mode                      = "API"
  enable_cluster_creator_admin_permissions = false

  access_entries = {
    admin = {
      principal_arn = local.admin_principal_arn
      policy_associations = {
        cluster_admin = {
          policy_arn   = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = { type = "cluster" }
        }
      }
    }

    jenkins_deployer = {
      principal_arn = aws_iam_role.jenkins_deployer.arn
      policy_associations = {
        portfolio_edit = {
          policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSEditPolicy"
          access_scope = {
            type       = "namespace"
            namespaces = ["portfolio"]
          }
        }
      }
    }
  }

  # Module v21 creates the cluster with bootstrap_self_managed_addons = false,
  # so the networking add-ons must exist for nodes to become Ready. vpc-cni is
  # installed before the node group. ebs-csi and metrics-server (Task 7) run
  # on the nodes, so they're created after the node group.
  addons = {
    vpc-cni = {
      before_compute = true
    }
    kube-proxy = {}
    coredns    = {}
    aws-ebs-csi-driver = {
      service_account_role_arn = module.irsa_ebs_csi.arn
    }
    # Needed for kubectl top and the memory/CPU HPA in Task 9.
    metrics-server = {}
  }

  eks_managed_node_groups = {
    default = {
      ami_type       = "AL2023_x86_64_STANDARD"
      instance_types = ["t3.medium"]
      capacity_type  = "ON_DEMAND"

      min_size     = 2
      desired_size = 2
      max_size     = 3

      # Module node SG (cluster/node rules) + our SG (8080 from ALB, endpoint access).
      vpc_security_group_ids = [aws_security_group.node.id]
      create_security_group  = false

      block_device_mappings = {
        xvda = {
          device_name = "/dev/xvda"
          ebs = {
            volume_size           = 20
            volume_type           = "gp3"
            encrypted             = true
            delete_on_termination = true
          }
        }
      }

      # IMDSv2 only, hop limit 1: pods can't reach the node role credentials.
      metadata_options = {
        http_endpoint               = "enabled"
        http_tokens                 = "required"
        http_put_response_hop_limit = 1
      }
    }
  }
}
