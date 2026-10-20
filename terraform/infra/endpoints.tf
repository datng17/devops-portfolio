# S3 gateway endpoint: free, always on. Carries ECR image layers (served from
# S3) so the bulk of image-pull bytes skip the NAT Gateway.
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = module.vpc.vpc_id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = module.vpc.private_route_table_ids

  tags = { Name = "${local.name}-s3" }
}

# Interface endpoints (ecr.api, ecr.dkr, logs, ...). Toggle with
# enable_interface_endpoints; each costs ~$0.01/h per AZ plus $0.01/GB.
resource "aws_vpc_endpoint" "interface" {
  for_each = var.enable_interface_endpoints ? toset(var.interface_endpoint_services) : toset([])

  vpc_id              = module.vpc.vpc_id
  service_name        = "com.amazonaws.${var.region}.${each.value}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = module.vpc.private_subnets
  security_group_ids  = [aws_security_group.endpoints.id]
  private_dns_enabled = true

  tags = { Name = "${local.name}-${replace(each.value, ".", "-")}" }
}
