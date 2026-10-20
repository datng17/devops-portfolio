output "lbc_release_status" {
  description = "Helm release status of the AWS Load Balancer Controller."
  value       = helm_release.aws_load_balancer_controller.status
}

output "lbc_chart_version" {
  description = "Installed aws-load-balancer-controller chart version."
  value       = helm_release.aws_load_balancer_controller.version
}

output "lbc_app_version" {
  description = "Installed AWS Load Balancer Controller app version."
  value       = helm_release.aws_load_balancer_controller.metadata.app_version
}

output "log_sink_config_file" {
  description = "Generated kustomize env file for k8s/platform."
  value       = local_file.log_sink_config.filename
}

output "cluster_name" {
  description = "EKS cluster name (from infra state)."
  value       = local.infra.cluster_name
}
