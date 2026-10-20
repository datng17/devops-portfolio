# Task 7 - IRSA roles and managed add-ons

## Status
- [ ] Not started / - [x] Done

## Objective
Least-privilege AWS identities for in-cluster components, and healthy core add-ons.

## Dependencies
Task 6.

## Files to create/modify
- `terraform/infra/irsa.tf`, `eks.tf` (addons), `outputs.tf`

## Implementation guidance
- IRSA roles, built with the iam module's IRSA submodule. Each trust policy is scoped to the OIDC `sub` and `aud`:
  - EBS CSI: `kube-system:ebs-csi-controller-sa`
  - LBC: `kube-system:aws-load-balancer-controller`
  - log-sink: `portfolio:log-sink`, with an inline policy for logs on one log group
- `aws_cloudwatch_log_group` `/eks/<name>/portfolio-nginx`, 7-day retention.
- Add-ons:
  - vpc-cni, kube-proxy, coredns: already created in Task 6 (keep them in the `addons` map)
  - Add aws-ebs-csi-driver (with role ARN) and metrics-server
  - Optional: pin add-on versions

## Test requirements
- `aws eks describe-addon --cluster-name <n> --addon-name <a>` shows ACTIVE for all five add-ons (vpc-cni, kube-proxy, coredns, aws-ebs-csi-driver, metrics-server).
- `kubectl top nodes` returns data.
- Inspect the trust policy JSON for the `sub`/`aud` conditions.

## Demo / acceptance criteria
All add-ons ACTIVE and metrics available.

## Interview talking points
- IRSA: the pod's projected token goes through `AssumeRoleWithWebIdentity`, and the trust policy pins the namespace and service account. Nodes never get EBS or ELB permissions.
- IRSA vs EKS Pod Identity: Pod Identity needs no OIDC provider and is simpler across clusters. IRSA works everywhere, including outside EKS. This build uses IRSA because the spec asked for it, and can explain the migration path.
- Without an STS interface endpoint, the token exchange goes out through the NAT. Adding `sts` to `interface_endpoint_services` closes that gap.
