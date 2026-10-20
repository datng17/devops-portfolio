# Task 4 - Security groups, VPC endpoints, ECR

## Status
- [ ] Not started / - [x] Done

## Objective
Least-privilege network paths, private AWS API access, and an image registry.

## Dependencies
Task 3.

## Files to create/modify
- `terraform/infra/security_groups.tf`, `endpoints.tf`, `ecr.tf`
- `terraform/infra/outputs.tf` (new; Task 3 did not create it)

## Implementation guidance
- ALB SG:
  - ingress: 80/443 from 0.0.0.0/0
  - egress: 8080 to the node SG only
- Endpoint SG: ingress 443 from the node SG.
- S3 Gateway endpoint on the private route tables, always on.
- Interface endpoints: `for_each` over `interface_endpoint_services`, created only when `enable_interface_endpoints` is true. Private DNS on, in the private subnets.
- ECR repo:
  - IMMUTABLE tags, scan on push, AES256
  - lifecycle policy keeping the last 20 images
- `outputs.tf`:
  - network: `vpc_id`, `public_subnet_ids`, `private_subnet_ids`, `private_route_table_ids`, `nat_gateway_id`
  - plus the SG, endpoint and ECR outputs (e.g. ALB/node/endpoint SG IDs, endpoint IDs, ECR repo URL)
  - Task 8 reads these through `terraform_remote_state`

## Test requirements
- `terraform output` shows the network, SG, endpoint and ECR outputs.
- The endpoints show as `available`.
- `terraform plan -var enable_interface_endpoints=false` destroys only the interface endpoints.
- A manual push of `portfolio:local` to ECR succeeds.

## Demo / acceptance criteria
The endpoints are live, the toggle works, and the image is in ECR.

## Interview talking points
- Security groups reference other security groups, not CIDRs, so the rules follow identity rather than IP addresses.
- ECR pulls need three things: `ecr.api` (auth), `ecr.dkr` (manifests) and S3 (layer blobs). The gateway endpoint is free and carries most of the bytes.
- Break-even for interface endpoints vs NAT is about 1.25 TB/month. Below that they're a security/private-path choice, which is why there's a toggle.
- Immutable tags plus SHA tags mean a tag always refers to the same bytes, so rollbacks are deterministic.
