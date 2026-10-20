# Task 6 - EKS cluster, node group, access

## Status
- [ ] Not started / - [x] Done

## Objective
A cluster with nodes in private subnets only, reachable by the admin and by Jenkins from allowed CIDRs only.

## Dependencies
Tasks 3, 4.

## Files to create/modify
- `terraform/infra/eks.tf`, `iam_jenkins.tf`, `security_groups.tf` (node rule)

## Prerequisites
- Install/verify AWS CLI v2: `aws --version` shows 2.x. The local CLI is v1, and `aws eks get-token`/`update-kubeconfig` (here and in Task 8) work best with v2.

## Implementation guidance
- eks module v21:
  - `name`, `kubernetes_version`
  - public endpoint limited to `admin_cidrs`, private endpoint enabled
  - control plane logs: api, audit, authenticator
  - `enable_irsa = true`, `authentication_mode = "API"`
  - private subnets
- Managed node group:
  - AL2023, t3.medium, min 2 / desired 2 / max 3
  - encrypted gp3 20 GB root volume, IMDSv2 required
- Node SG: TCP 8080 from the ALB SG.
- IAM user `jenkins-ci` can only `sts:AssumeRole` into `jenkins-deployer`. That role gets:
  - ECR push/pull on the repo ARN
  - `ecr:GetAuthorizationToken`
  - `eks:DescribeCluster`
- Access entries:
  - admin → `AmazonEKSClusterAdminPolicy` (cluster scope)
  - jenkins-deployer → `AmazonEKSEditPolicy` (namespace `portfolio`)

## Test requirements
- `aws eks update-kubeconfig --region us-east-1 --name <name>`
- `kubectl get nodes -o wide` shows 2 nodes in different AZs with no external IP.

## Demo / acceptance criteria
The cluster is reachable from the admin IP only, and the nodes have private IPs only.

## Interview talking points
- Access entries are managed through the EKS API, auditable in CloudTrail and handled by Terraform. Unlike the old `aws-auth` ConfigMap, a bad edit can't lock you out.
- Jenkins can deploy only into `portfolio`. It can't touch `kube-system` or the cluster itself.
- Jenkins uses short-lived assumed-role credentials. The long-lived user key can do nothing except assume that role.
- IMDSv2 with hop limit 1 stops pods from stealing the node role through the metadata service.
