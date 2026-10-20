# AWS Load Balancer Controller. Reconciles the app Ingress (Task 9) into an
# internet-facing ALB. IAM comes from the IRSA role created in terraform/infra;
# region and vpcId are passed explicitly so the controller never needs IMDS.
resource "helm_release" "aws_load_balancer_controller" {
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  version    = var.lbc_chart_version
  namespace  = "kube-system"

  wait    = true
  atomic  = true
  timeout = 600

  values = [yamlencode({
    clusterName  = local.infra.cluster_name
    region       = var.region
    vpcId        = local.infra.vpc_id
    replicaCount = var.lbc_replica_count

    serviceAccount = {
      create = true
      name   = "aws-load-balancer-controller"
      annotations = {
        "eks.amazonaws.com/role-arn" = local.infra.lbc_irsa_role_arn
      }
    }

    # Keep one controller up during node drains (Task 11 drills).
    podDisruptionBudget = {
      maxUnavailable = 1
    }
  })]
}

# Generated, gitignored kustomize input for k8s/platform (configMapGenerator +
# replacements). Keeps account-specific ARNs out of committed manifests.
resource "local_file" "log_sink_config" {
  filename        = coalesce(var.log_sink_config_path, "${path.module}/../../k8s/platform/log-sink-config.env")
  file_permission = "0644"
  content         = <<-EOT
    CW_REGION=${var.region}
    LOG_GROUP_NAME=${local.infra.portfolio_nginx_log_group_name}
    LOG_SINK_ROLE_ARN=${local.infra.log_sink_irsa_role_arn}
  EOT
}
