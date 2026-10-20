locals {
  name = "${var.project}-${var.environment}"

  # Public /24s: 10.0.0.0/24, 10.0.1.0/24 (ALB + NAT only, little IP demand).
  public_subnets = [for i, _ in var.azs : cidrsubnet(var.vpc_cidr, 8, i)]

  # Private /20s: 10.0.16.0/20, 10.0.32.0/20. Large because the VPC CNI gives
  # every pod a VPC IP. Offset by 1 so they don't overlap the public /24s.
  private_subnets = [for i, _ in var.azs : cidrsubnet(var.vpc_cidr, 4, i + 1)]

  cluster_tag = { "kubernetes.io/cluster/${var.cluster_name}" = "shared" }
}
