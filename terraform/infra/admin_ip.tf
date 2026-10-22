# EKS public API allowlist = static admin_cidrs + (optionally) the current
# public IP of the machine running Terraform. The home connection has a
# dynamic IP, so hardcoding it breaks kubectl/Jenkins whenever the ISP
# reassigns it. Between applies, scripts/sync-admin-ip.ps1 applies the same
# rule through the AWS CLI, so the next plan shows no drift.

data "http" "admin_ip" {
  count = var.auto_detect_admin_ip ? 1 : 0

  url = "https://checkip.amazonaws.com"

  request_timeout_ms = 10000
  retry {
    attempts     = 3
    min_delay_ms = 1000
  }

  lifecycle {
    postcondition {
      condition     = self.status_code == 200 && can(cidrhost("${trimspace(self.response_body)}/32", 0))
      error_message = "Could not detect the public IP from https://checkip.amazonaws.com. Set auto_detect_admin_ip = false and list the IP in admin_cidrs instead."
    }
  }
}

locals {
  detected_admin_cidr = var.auto_detect_admin_ip ? ["${trimspace(data.http.admin_ip[0].response_body)}/32"] : []

  # Sorted so the order never causes a diff (EKS returns the list sorted too).
  admin_cidrs = sort(distinct(concat(var.admin_cidrs, local.detected_admin_cidr)))
}
