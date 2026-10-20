# Public TLS certificate for the ALB. The certificate is managed OUTSIDE
# Terraform (requested and DNS-validated manually in ACM), so
# `terraform destroy` never deletes it. Terraform only looks it up.
#
# To create one: request a public DNS-validated cert for var.domain_name in
# us-east-1, add the validation CNAME at the DNS provider, wait for ISSUED.
# Delete it manually (console or `aws acm delete-certificate`) when no longer
# needed; keep the validation CNAME so auto-renewal keeps working.
data "aws_acm_certificate" "this" {
  domain      = var.domain_name
  statuses    = ["ISSUED"]
  types       = ["AMAZON_ISSUED"]
  most_recent = true
}
