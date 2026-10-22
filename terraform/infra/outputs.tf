# Network
output "vpc_id" {
  description = "VPC ID."
  value       = module.vpc.vpc_id
}

output "public_subnet_ids" {
  description = "Public subnet IDs (ALB, NAT)."
  value       = module.vpc.public_subnets
}

output "private_subnet_ids" {
  description = "Private subnet IDs (nodes, interface endpoints)."
  value       = module.vpc.private_subnets
}

output "private_route_table_ids" {
  description = "Private route table IDs."
  value       = module.vpc.private_route_table_ids
}

output "nat_gateway_id" {
  description = "ID of the single NAT Gateway."
  value       = one(module.vpc.natgw_ids)
}

# Security groups
output "alb_security_group_id" {
  description = "ALB security group ID (used in the Ingress security-groups annotation)."
  value       = aws_security_group.alb.id
}

output "node_security_group_id" {
  description = "Additional node security group ID."
  value       = aws_security_group.node.id
}

output "endpoint_security_group_id" {
  description = "Interface endpoint security group ID."
  value       = aws_security_group.endpoints.id
}

# VPC endpoints
output "s3_gateway_endpoint_id" {
  description = "S3 gateway endpoint ID."
  value       = aws_vpc_endpoint.s3.id
}

output "interface_endpoint_ids" {
  description = "Interface endpoint IDs keyed by service (empty when disabled)."
  value       = { for svc, ep in aws_vpc_endpoint.interface : svc => ep.id }
}

# ECR
output "ecr_repository_name" {
  description = "ECR repository name."
  value       = aws_ecr_repository.app.name
}

output "ecr_repository_url" {
  description = "ECR repository URL (<account>.dkr.ecr.<region>.amazonaws.com/<name>)."
  value       = aws_ecr_repository.app.repository_url
}

output "ecr_repository_arn" {
  description = "ECR repository ARN (for the Jenkins deployer policy)."
  value       = aws_ecr_repository.app.arn
}

# ACM
output "acm_certificate_arn" {
  description = "ARN of the externally managed ISSUED ACM certificate (Ingress certificate-arn annotation)."
  value       = data.aws_acm_certificate.this.arn
}

output "acm_certificate_status" {
  description = "ACM certificate status (always ISSUED; the lookup fails otherwise)."
  value       = data.aws_acm_certificate.this.status
}

# EKS
output "cluster_name" {
  description = "EKS cluster name."
  value       = module.eks.cluster_name
}

output "cluster_arn" {
  description = "EKS cluster ARN."
  value       = module.eks.cluster_arn
}

output "cluster_endpoint" {
  description = "EKS API server endpoint."
  value       = module.eks.cluster_endpoint
}

output "cluster_certificate_authority_data" {
  description = "Base64 cluster CA certificate (for the platform helm/kubernetes providers)."
  value       = module.eks.cluster_certificate_authority_data
}

output "cluster_version" {
  description = "EKS Kubernetes version."
  value       = module.eks.cluster_version
}

output "cluster_security_group_id" {
  description = "Cluster (control plane) security group ID created by the eks module."
  value       = module.eks.cluster_security_group_id
}

output "eks_node_security_group_id" {
  description = "Shared node security group ID created by the eks module (node_security_group_id is the additional SG)."
  value       = module.eks.node_security_group_id
}

output "cluster_oidc_issuer_url" {
  description = "OIDC issuer URL (IRSA)."
  value       = module.eks.cluster_oidc_issuer_url
}

output "oidc_provider_arn" {
  description = "IAM OIDC provider ARN (IRSA trust policies)."
  value       = module.eks.oidc_provider_arn
}

output "node_iam_role_arn" {
  description = "IAM role ARN of the default managed node group."
  value       = module.eks.eks_managed_node_groups["default"].iam_role_arn
}

output "kubeconfig_command" {
  description = "Command to configure kubectl for the cluster."
  value       = "aws eks update-kubeconfig --region ${var.region} --name ${module.eks.cluster_name}"
}

# Jenkins
output "jenkins_ci_user_name" {
  description = "IAM user for Jenkins (create its access key outside Terraform)."
  value       = aws_iam_user.jenkins_ci.name
}

output "jenkins_ci_user_arn" {
  description = "IAM user ARN for Jenkins."
  value       = aws_iam_user.jenkins_ci.arn
}

output "jenkins_deployer_role_arn" {
  description = "Role Jenkins assumes for ECR push and kubectl deploys to the portfolio namespace."
  value       = aws_iam_role.jenkins_deployer.arn
}

# IRSA
output "ebs_csi_irsa_role_arn" {
  description = "IRSA role ARN for the EBS CSI driver (kube-system:ebs-csi-controller-sa)."
  value       = module.irsa_ebs_csi.arn
}

output "lbc_irsa_role_arn" {
  description = "IRSA role ARN for the AWS Load Balancer Controller ServiceAccount annotation."
  value       = module.irsa_lbc.arn
}

output "log_sink_irsa_role_arn" {
  description = "IRSA role ARN for the log-sink ServiceAccount annotation (portfolio:log-sink)."
  value       = module.irsa_log_sink.arn
}

output "portfolio_nginx_log_group_name" {
  description = "CloudWatch log group the log-sink writes Nginx access logs to."
  value       = aws_cloudwatch_log_group.portfolio_nginx.name
}

output "admin_cidrs" {
  description = "Effective EKS public API allowlist (static admin_cidrs + detected IP)."
  value       = local.admin_cidrs
}

output "admin_cidrs_static" {
  description = "Static admin_cidrs only; scripts/sync-admin-ip.ps1 adds the current IP to these."
  value       = var.admin_cidrs
}
