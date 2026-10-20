# Task 3 - Terraform bootstrap and VPC

## Status
- [ ] Not started / - [x] Done

## Objective
Remote state and a tagged multi-AZ network.

## Dependencies
None (AWS account access needed to apply).

## Files to create/modify
- `terraform/bootstrap/{main,variables,outputs}.tf`
- `terraform/infra/{versions,backend,providers,variables,locals,vpc}.tf`
- `terraform/infra/terraform.tfvars.example`, `terraform/infra/backend.hcl.example`
- `.gitignore`

## Implementation guidance
- `bootstrap/` creates an S3 bucket with versioning, SSE, a public access block and a TLS-only bucket policy. This root keeps local state.
- In `infra/`:
  - require Terraform >= 1.10 and pin the AWS provider
  - S3 backend with `use_lockfile = true`, bucket and key passed through `-backend-config=backend.hcl`
  - `default_tags`: Project, Environment, ManagedBy
- VPC module:
  - 10.0.0.0/16 across 2 AZs, public /24 and private /20 subnets
  - single NAT Gateway, DNS hostnames and support on
  - subnet tags: `kubernetes.io/role/elb=1` (public), `kubernetes.io/role/internal-elb=1` (private), `kubernetes.io/cluster/<name>=shared` (both)

## As-built
- Applied in us-east-1.
- State bucket `eks-portfolio-tfstate-<account_id>-us-east-1`: versioning, AES256 + bucket key, public access block, BucketOwnerEnforced, TLS-only policy, 90-day noncurrent-version expiry, `prevent_destroy`.
- Infra state key `infra/terraform.tfstate`.
- VPC module `terraform-aws-modules/vpc/aws` 6.7.3, AWS provider `~> 6.69`.
- Public subnets 10.0.0.0/24 and 10.0.1.0/24; private subnets 10.0.16.0/20 and 10.0.32.0/20; one NAT Gateway in us-east-1a.
- `backend.hcl` and `terraform.tfvars` are local and gitignored. `.terraform.lock.hcl` is committed.
- On Windows/pwsh, init with `terraform init "-backend-config=backend.hcl"` (unquoted fails with "No positional arguments are expected").
- No `outputs.tf` yet; Task 4 adds the VPC/subnet outputs.
- Running cost is about $36.50/mo (NAT + EIP) until teardown.

## Test requirements
- `terraform fmt -check -recursive`, `terraform validate` and `terraform plan` pass.
- Apply only after the user confirms.
- `aws ec2 describe-subnets --filters Name=tag:kubernetes.io/role/elb,Values=1` returns 2 subnets in different AZs.

## Demo / acceptance criteria
The VPC exists with correctly tagged subnets in both AZs.

## Interview talking points
- Native S3 locking (`use_lockfile`, Terraform 1.10+) replaces the DynamoDB lock table.
- Private subnets are /20s because the VPC CNI gives every pod a VPC IP, so pod density uses up addresses.
- Single NAT Gateway: it saves about $32/mo plus cross-AZ data. The cost is that AZ-a failure removes internet egress for both AZs. The VPC endpoints soften that for AWS APIs.
- The subnet role tags are how the Load Balancer Controller finds the subnets, so no subnet IDs are hardcoded in the Ingress.
