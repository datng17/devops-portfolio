# Security group chain (SG-to-SG references, no CIDRs inside the VPC):
#   internet --80/443--> ALB SG --8080--> node SG --443--> endpoint SG
# Rules use the standalone aws_vpc_security_group_*_rule resources so that
# later tasks (e.g. Task 6 node ingress) can add rules without conflicts.

# ALB security group. Passed to the Ingress via the alb.ingress.kubernetes.io/
# security-groups annotation with manage-backend-security-group-rules="false".
resource "aws_security_group" "alb" {
  name        = "${local.name}-alb"
  description = "Public ALB: HTTP/HTTPS from the internet, 8080 to nodes only"
  vpc_id      = module.vpc.vpc_id

  tags = { Name = "${local.name}-alb" }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "alb_http" {
  security_group_id = aws_security_group.alb.id
  description       = "HTTP from the internet (redirected to HTTPS)"
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_ingress_rule" "alb_https" {
  security_group_id = aws_security_group.alb.id
  description       = "HTTPS from the internet"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_egress_rule" "alb_to_nodes" {
  security_group_id            = aws_security_group.alb.id
  description                  = "App traffic to pods (nginx 8080) on nodes only"
  ip_protocol                  = "tcp"
  from_port                    = 8080
  to_port                      = 8080
  referenced_security_group_id = aws_security_group.node.id
}

# Additional node security group, attached to the managed node group (eks.tf)
# next to the module's node SG. VPC CNI copies it to pod ENIs, so the ALB
# (target-type ip) reaches pods on 8080.
resource "aws_security_group" "node" {
  name        = "${local.name}-node"
  description = "EKS worker nodes (additional SG)"
  vpc_id      = module.vpc.vpc_id

  tags = { Name = "${local.name}-node" }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "node_from_alb" {
  security_group_id            = aws_security_group.node.id
  description                  = "App traffic (nginx 8080) from the ALB only"
  ip_protocol                  = "tcp"
  from_port                    = 8080
  to_port                      = 8080
  referenced_security_group_id = aws_security_group.alb.id
}

# Nginx pods on any node send syslog to the log-sink pod (Task 8). The eks
# module's node-to-node rules only cover TCP ephemeral ports and DNS, so
# cross-node UDP 5140 would be dropped without this.
resource "aws_vpc_security_group_ingress_rule" "node_syslog_from_nodes" {
  security_group_id            = aws_security_group.node.id
  description                  = "Syslog (UDP 5140) to log-sink from pods on other nodes"
  ip_protocol                  = "udp"
  from_port                    = 5140
  to_port                      = 5140
  referenced_security_group_id = aws_security_group.node.id
}

resource "aws_vpc_security_group_egress_rule" "node_all" {
  security_group_id = aws_security_group.node.id
  description       = "Node egress (VPC endpoints, NAT for everything else)"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

# Interface VPC endpoint security group.
resource "aws_security_group" "endpoints" {
  name        = "${local.name}-vpce"
  description = "Interface VPC endpoints: HTTPS from nodes only"
  vpc_id      = module.vpc.vpc_id

  tags = { Name = "${local.name}-vpce" }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "endpoints_from_nodes" {
  security_group_id            = aws_security_group.endpoints.id
  description                  = "HTTPS from EKS nodes"
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443
  referenced_security_group_id = aws_security_group.node.id
}
