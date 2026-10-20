# EKS DevOps Portfolio - Overview

## Problem statement
`react-portfolio-template` is a static Create React App portfolio (React 18, TypeScript, react-scripts 5) that was set up for GitHub Pages and had one broken test. The goal is a reproducible, production-grade AWS deployment that holds up in a technical interview:

- Terraform IaC
- EKS with IRSA
- Jenkins → ECR → EKS CI/CD
- a resilient Kubernetes workload behind an HTTPS ALB on `test.name.vn`
- least-privilege networking in `us-east-1`

## Requirements / decisions
| Area | Decision |
|---|---|
| DNS | Hosted outside AWS. Terraform creates the ACM certificate (DNS validation). The user adds the validation CNAME and `test.name.vn` → ALB CNAME by hand. No Route 53 zone. |
| Cost | 2 AZs, **one** NAT Gateway. S3 Gateway endpoint always on. Interface endpoints (`ecr.api`, `ecr.dkr`, `logs`) behind `enable_interface_endpoints` (default `true`); services list in `interface_endpoint_services` so `sts` can be added. |
| Jenkins | Runs locally in Docker with the host Docker socket mounted. Custom image with AWS CLI v2, kubectl, kustomize and Node 22. EKS endpoint public (limited to `admin_cidrs`) plus private. |
| Persistence | App is a stateless Deployment. The gp3 PVC belongs to a one-replica `log-sink` StatefulSet (Fluent Bit) that receives Nginx syslog on UDP 5140 and writes to the PVC and to CloudWatch Logs. |
| Terraform | `terraform-aws-modules` (vpc, eks v21, iam). S3 backend with `use_lockfile = true`. Roots: `bootstrap`, `infra`, `platform`. |
| Versions | Latest EKS standard-support version (1.37 at planning), eks module v21.29.x, AWS LBC v3.6.x, AL2023 nodes, t3.medium, node:22-alpine, nginx-unprivileged stable alpine. |

## Research findings
- `package.json` `homepage` points to the github.io subpath, so a plain build serves `/react-portfolio-template/static/...` and the page is blank at `test.name.vn`. The Docker build sets `PUBLIC_URL=/`, and `homepage` stays as it is so GitHub Pages still works.
- `App.test.tsx` looked for "learn react", which isn't on the page. jsdom has no `window.scrollTo` or `IntersectionObserver`, so both are mocked.
- EBS is zonal and ReadWriteOnce, so it stays off the HPA tier (hence `log-sink`).
- A *required* zone anti-affinity across 2 AZs leaves replicas 3-5 Pending. The Deployment uses *preferred* anti-affinity plus `topologySpreadConstraints` (maxSkew 1, ScheduleAnyway) and a PDB with `minAvailable: 1`.
- Memory-based HPA needs metrics-server, installed as an EKS add-on.
- Security group chain: Terraform owns the ALB SG (80/443 from 0.0.0.0/0). The Ingress uses `security-groups` with `manage-backend-security-group-rules: "false"`, and the node SG allows TCP 8080 **from the ALB SG only**. The endpoint SG allows 443 from the node SG.
- Interface endpoints cost 3 × 2 AZ = $43.80/mo and save $0.035/GB compared with NAT. Break-even is about **1,251 GB/month**. ECR layers are served from S3, which the free gateway endpoint already covers, so the interface endpoints are a private-path/security choice, not a cost saving at this scale.
- Teardown has to delete the Ingress and PVC/PV before `terraform destroy`. Otherwise the ALB and ENIs block VPC deletion.
- Access is through EKS access entries (`authentication_mode = "API"`), not the `aws-auth` ConfigMap.
- Nginx resolves the syslog host at startup, so the `log-sink` Service has to exist before app pods start (the platform layer is applied first).

## Architecture
```mermaid
flowchart LR
  U[User] -->|HTTPS test.name.vn<br/>manual CNAME| ALB
  subgraph VPC 10.0.0.0/16 - us-east-1a / us-east-1b
    subgraph Public subnets elb=1
      ALB[ALB + ACM cert<br/>ALB SG: 80/443 from 0.0.0.0/0]
      NAT[NAT GW single]
    end
    subgraph Private subnets internal-elb=1
      N1[Node AZ-a] --- N2[Node AZ-b]
      P[portfolio pods 2-5<br/>HPA, nginx:8080] -->|syslog UDP| LS[log-sink StatefulSet<br/>gp3 PVC]
      EP[Interface endpoints<br/>ecr.api / ecr.dkr / logs]
    end
    ALB -->|8080 from ALB SG only| P
    S3GW[S3 Gateway endpoint]
  end
  N1 & N2 --> EP & S3GW
  N1 & N2 -->|other egress| NAT
  LS --> EP --> CW[CloudWatch Logs]
  J[Local Jenkins Docker] -->|push| ECR[(ECR)]
  J -->|kubectl via public endpoint<br/>restricted CIDR, access entry| EKS[EKS API]
```

## Directory layout
```
react-portfolio-template/
├── Dockerfile, .dockerignore, Jenkinsfile
├── nginx/nginx.conf
├── src/App.test.tsx, src/setupTests.ts
├── terraform/
│   ├── bootstrap/   state bucket
│   ├── infra/       vpc, security_groups, endpoints, acm, ecr, eks, irsa, iam_jenkins, outputs
│   └── platform/    AWS Load Balancer Controller (helm)
├── k8s/
│   ├── platform/    namespace, storageclass-gp3, log-sink
│   ├── app/         deployment, service, pdb, hpa, ingress, sa, nginx-logging
│   └── tests/       k6 load-test Job
├── jenkins/         Dockerfile, plugins.txt, docker-compose.yml
├── scripts/         smoke-test.sh, verify-rollout.sh, hpa-load-test.sh, teardown.sh, render-k8s-config.ps1
└── docs/deployment-guide.md
```

## Cost estimate (us-east-1 list prices, re-check before apply)
| Component | Monthly |
|---|---|
| EKS control plane ($0.10/h) | $73.00 |
| 2× t3.medium ($0.0416/h) | $60.74 |
| NAT GW + EIP ($0.045/h + $0.005/h, +$0.045/GB) | $36.50 |
| ALB (~1 LCU + public IPs) | ~$29 |
| Interface endpoints 3×2 AZ ($0.01/h each, +$0.01/GB) | $43.80 |
| S3 Gateway endpoint | $0 |
| gp3 2×20 GB + 5 GB ($0.08/GB-mo) | $3.60 |
| ECR + CloudWatch Logs | ~$2 |
| **Total (endpoints on / off)** | **~$248 / ~$205** |

## Task index
| # | File |
|---|---|
| 1 | [task-01-app-ci-readiness.md](task-01-app-ci-readiness.md) |
| 2 | [task-02-docker-image.md](task-02-docker-image.md) |
| 3 | [task-03-terraform-bootstrap-vpc.md](task-03-terraform-bootstrap-vpc.md) |
| 4 | [task-04-security-groups-endpoints-ecr.md](task-04-security-groups-endpoints-ecr.md) |
| 5 | [task-05-acm-certificate.md](task-05-acm-certificate.md) |
| 6 | [task-06-eks-cluster-access.md](task-06-eks-cluster-access.md) |
| 7 | [task-07-irsa-addons.md](task-07-irsa-addons.md) |
| 8 | [task-08-platform-lbc-storage-logsink.md](task-08-platform-lbc-storage-logsink.md) |
| 9 | [task-09-app-manifests-ingress.md](task-09-app-manifests-ingress.md) |
| 10 | [task-10-jenkins-pipeline.md](task-10-jenkins-pipeline.md) |
| 11 | [task-11-resilience-hpa-tests.md](task-11-resilience-hpa-tests.md) |
| 12 | [task-12-guide-cost-teardown.md](task-12-guide-cost-teardown.md) |

## Execution safety rules
- Tasks 1-2 are local only.
- Any `terraform apply/destroy`, `helm install` or `kubectl apply` against AWS needs explicit user confirmation, with the plan summary and cost shown first.
- No hardcoded secrets or account IDs. Values go in `terraform.tfvars` (gitignored), with a `terraform.tfvars.example` committed.
- The user adds DNS records by hand. Execution pauses and gives the exact values.
