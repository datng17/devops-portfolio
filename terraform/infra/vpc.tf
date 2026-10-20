module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "6.7.3"

  name = local.name
  cidr = var.vpc_cidr
  azs  = var.azs

  public_subnets  = local.public_subnets
  private_subnets = local.private_subnets

  # One NAT Gateway for both AZs: cheaper, at the cost of AZ-a egress being a
  # single point of failure (VPC endpoints cover AWS API traffic).
  enable_nat_gateway     = true
  single_nat_gateway     = true
  one_nat_gateway_per_az = false

  enable_dns_hostnames = true
  enable_dns_support   = true

  # Subnet discovery for the AWS Load Balancer Controller.
  public_subnet_tags = merge(local.cluster_tag, {
    "kubernetes.io/role/elb" = "1"
  })

  private_subnet_tags = merge(local.cluster_tag, {
    "kubernetes.io/role/internal-elb" = "1"
  })
}
