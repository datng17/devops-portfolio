# Task 12 - Deployment guide, cost validation, teardown

## Status
- [ ] Not started / - [x] Done

## Objective
Everything can be reproduced from the docs and shut down safely.

## Dependencies
All previous tasks.

## Files to create/modify
- `docs/deployment-guide.md`
- `scripts/teardown.sh`

## Implementation guidance
- The guide covers:
  - prerequisites
  - the ordered commands: bootstrap → infra (ACM two-phase) → platform → k8s/platform → first deploy → Jenkins
  - Windows/pwsh commands quote the backend argument: `terraform init "-backend-config=backend.hcl"`
  - verification commands
  - the cost table and break-even math
  - interview talking points
- `teardown.sh`, in order:
  1. delete the Ingress and wait for the ALB to disappear
  2. delete the app and platform resources and the PVCs/PVs/EBS volumes
  3. `terraform destroy` platform, then infra
  4. keep the state bucket (it has `prevent_destroy`)
  5. check for leftover resources
- Confirmation prompt before destroy.
- Removing the state bucket is a manual step, not part of `teardown.sh`: remove the lifecycle block, empty all object versions, then destroy.

## Test requirements
After teardown, no ALBs, ENIs or EBS volumes tagged for the cluster remain.

## Demo / acceptance criteria
One command brings the cost to about $0/day.

## Interview talking points
- Controller-created resources (ALB, EBS) live outside Terraform state. Delete them first, or `destroy` gets stuck on VPC dependencies.
- Spending about $0.34/h only while demoing, instead of about $248/mo, is FinOps in practice.
