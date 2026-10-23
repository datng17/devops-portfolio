# Implementation Plan: EKS Portfolio

## Overview

Containerize the React portfolio, provision AWS infrastructure (VPC, endpoints, ECR, ACM, EKS, IRSA, add-ons) with Terraform, deploy a platform layer and an HA app behind an HTTPS ALB Ingress, wire up a Jenkins pipeline with automatic rollback, verify resilience/HPA, and document deployment, cost, and teardown. Full context is in `00-overview.md`; each task below links to its detail file.

## Tasks

- [x] 1. Task 1 - Make the app CI-ready
  - [x] 1.1 Add jsdom mocks to `src/setupTests.ts`
    - Mock `window.scrollTo` and `IntersectionObserver` so components render under jsdom
    - Details: task-01-app-ci-readiness.md
  - [x] 1.2 Rewrite `src/App.test.tsx`
    - Replace the default CRA "learn react" test
    - Test: app renders without crashing
    - Test: name heading, Expertise and Contact Me sections are present
    - Test: mode toggle switches the `dark-mode`/`light-mode` class
    - Details: task-01-app-ci-readiness.md
  - [x] 1.3 Add CI scripts to `package.json` and fix lint warnings
    - Add `"lint": "eslint --max-warnings=0 src"` and `"test:ci": "react-scripts test --watchAll=false --coverage"`
    - Fix any lint warnings that come up
    - Verify `$env:CI='true'; npm run test:ci` exits 0
    - Verify `npm run lint` exits 0
    - Details: task-01-app-ci-readiness.md

- [x] 2. Task 2 - Production Docker image
  - Depends on: Task 1
  - Create `Dockerfile`, `.dockerignore`, `nginx/nginx.conf`, `scripts/smoke-test.sh`, `.gitattributes` (LF line endings for `*.sh`, `nginx/*.conf`, `Dockerfile`)
  - Stage 1 `node:22-alpine` (digest-pinned): `npm ci` with BuildKit cache mount, `ARG PUBLIC_URL=/`, `npm run build`
  - Stage 2 `nginxinc/nginx-unprivileged:<stable>-alpine` (digest-pinned): UID 101, port 8080, `COPY --chown=101:101`
  - nginx.conf: SPA fallback, `/healthz` 200 `ok`, gzip, `/static/` 1-year immutable cache, `index.html` no-cache, security headers, `server_tokens off`, stdout access log plus `include /etc/nginx/logging/*.conf`, pid/temp paths under `/tmp`
  - `HEALTHCHECK` via busybox `wget`; smoke test checks `/healthz`, `/` HTML, a hashed static asset, and deep-link fallback
  - Test: `docker build -t portfolio:local .`, `docker run -d -p 8080:8080 --read-only --tmpfs /tmp portfolio:local`, `bash scripts/smoke-test.sh http://localhost:8080`
  - Test: `docker inspect` shows user `101`; image is about 30 MB or less
  - Details: task-02-docker-image.md

- [x] 3. Task 3 - Terraform bootstrap and VPC
  - Depends on: none (AWS account access needed to apply)
  - Create `terraform/bootstrap/{main,variables,outputs}.tf`: S3 state bucket with versioning, SSE, public access block, TLS-only policy (local state)
  - Create `terraform/infra/{versions,backend,providers,variables,locals,vpc}.tf`, `terraform.tfvars.example`, `backend.hcl.example`; update `.gitignore`
  - Terraform >= 1.10, pinned AWS provider, S3 backend with `use_lockfile = true` via `-backend-config=backend.hcl`, `default_tags` Project/Environment/ManagedBy
  - VPC module: 10.0.0.0/16, 2 AZs, public /24 and private /20 subnets, single NAT Gateway, DNS hostnames/support on, ELB role and cluster subnet tags
  - Test: `terraform fmt -check -recursive`, `terraform validate`, `terraform plan` pass
  - Test: `aws ec2 describe-subnets --filters Name=tag:kubernetes.io/role/elb,Values=1` returns 2 subnets in different AZs
  - Requires explicit user confirmation with plan summary and cost before applying.
  - As-built:
    - Applied in us-east-1; state bucket `eks-portfolio-tfstate-<account_id>-us-east-1` (versioning, AES256 + bucket key, public access block, BucketOwnerEnforced, TLS-only policy, 90-day noncurrent-version expiry, `prevent_destroy`)
    - Infra state key `infra/terraform.tfstate`; VPC module `terraform-aws-modules/vpc/aws` 6.7.3, AWS provider `~> 6.69`
    - Public subnets 10.0.0.0/24, 10.0.1.0/24; private subnets 10.0.16.0/20, 10.0.32.0/20; one NAT Gateway in us-east-1a
    - `backend.hcl` and `terraform.tfvars` are local and gitignored; `.terraform.lock.hcl` is committed
    - Running cost about $36.50/mo (NAT + EIP) until teardown
  - Details: task-03-terraform-bootstrap-vpc.md

- [x] 4. Task 4 - Security groups, VPC endpoints, ECR
  - Depends on: Task 3 (and the Task 2 image for the manual ECR push test)
  - Create/modify `terraform/infra/security_groups.tf`, `endpoints.tf`, `ecr.tf`
  - Create `terraform/infra/outputs.tf` (does not exist yet): `vpc_id`, `public_subnet_ids`, `private_subnet_ids`, `private_route_table_ids`, `nat_gateway_id`, plus SG, endpoint and ECR outputs
  - ALB SG: ingress 80/443 from 0.0.0.0/0, egress 8080 to node SG only; endpoint SG: 443 from node SG
  - S3 Gateway endpoint on private route tables; interface endpoints `for_each` over `interface_endpoint_services`, gated by `enable_interface_endpoints`, private DNS on
  - ECR repo: IMMUTABLE tags, scan on push, AES256, lifecycle keeps last 20 images
  - Test: endpoints show `available`; `terraform plan -var enable_interface_endpoints=false` destroys only interface endpoints; manual push of `portfolio:local` succeeds
  - Test: `terraform output` shows the VPC, subnet, route table, NAT, SG, endpoint and ECR outputs
  - Requires explicit user confirmation with plan summary and cost before applying.
  - Details: task-04-security-groups-endpoints-ecr.md

- [x] 5. Task 5 - ACM certificate (two-phase)
  - Depends on: Task 3
  - Create `terraform/infra/acm.tf` plus variables and outputs
  - `aws_acm_certificate` with DNS validation and `create_before_destroy`; output `domain_validation_options` and certificate ARN
  - `aws_acm_certificate_validation` gated by `acm_wait_for_validation` (default false)
  - Test: apply, user adds the validation CNAME, `aws acm wait certificate-validated --certificate-arn <arn>`, set `acm_wait_for_validation = true` and apply again
  - Test: `aws acm describe-certificate` shows `Status: ISSUED`
  - Requires explicit user confirmation with plan summary and cost before applying.
  - As-built:
    - Cert for `test.name.vn` was requested and DNS-validated outside Terraform, so it was imported (not re-requested) through a conditional `import` block driven by `acm_import_certificate_arn` (set only in the local `terraform.tfvars`)
    - Config matches the existing cert (DNS validation, RSA_2048, no extra SANs); the import changed tags only, with no replacement; `acm_wait_for_validation = true` (phase 2) and the validation resource completed instantly
    - Outputs: `acm_certificate_arn` (for the Task 9 Ingress), `acm_certificate_status`, `acm_domain_validation_options`; a follow-up plan shows no changes
    - Keep the validation CNAME at the DNS provider so auto-renewal works; `terraform destroy` now deletes the cert
  - Details: task-05-acm-certificate.md

- [x] 6. Task 6 - EKS cluster, node group, access
  - Depends on: Tasks 3, 4
  - Prerequisite: install/verify AWS CLI v2 (`aws --version` shows 2.x); the local CLI is v1, and `aws eks get-token`/`update-kubeconfig` work best with v2
  - Create/modify `terraform/infra/eks.tf`, `iam_jenkins.tf`, `security_groups.tf` (node rule)
  - eks module v21: public endpoint limited to `admin_cidrs`, private endpoint on, api/audit/authenticator logs, `enable_irsa = true`, `authentication_mode = "API"`, private subnets
  - Managed node group: AL2023, t3.medium, min 2 / desired 2 / max 3, encrypted gp3 20 GB root, IMDSv2 required
  - Node SG: TCP 8080 from ALB SG
  - IAM user `jenkins-ci` can only assume `jenkins-deployer` (ECR push/pull on repo, `ecr:GetAuthorizationToken`, `eks:DescribeCluster`)
  - Access entries: admin → `AmazonEKSClusterAdminPolicy` (cluster); jenkins-deployer → `AmazonEKSEditPolicy` (namespace `portfolio`)
  - Test: `aws eks update-kubeconfig --region us-east-1 --name <name>`; `kubectl get nodes -o wide` shows 2 nodes in different AZs with no external IP
  - Requires explicit user confirmation with plan summary and cost before applying.
  - As-built:
    - Applied in us-east-1 (43 resources). eks module `21.29.0`, cluster `eks-portfolio` on Kubernetes 1.37, `upgrade_policy` STANDARD (no extended-support billing), secrets encrypted with a module KMS key, control plane log group kept 7 days (`cluster_log_retention_days`)
    - Public endpoint limited to `admin_cidrs` (required var, rejects 0.0.0.0/0; set in local `terraform.tfvars`). Private endpoint is on
    - Admin access entry goes to `admin_principal_arn`, or to the identity running Terraform when that's null. `enable_cluster_creator_admin_permissions = false`
    - Beyond the spec: module v21 hardcodes `bootstrap_self_managed_addons = false`, so the managed add-ons vpc-cni (`before_compute`), kube-proxy and coredns are created here (ACTIVE); otherwise nodes never become Ready. Task 7 only adds aws-ebs-csi-driver and metrics-server (and may pin versions or set the IRSA role on vpc-cni)
    - Node group `default`: AL2023, 2× t3.medium, one node in us-east-1a and one in us-east-1b, private IPs only. It has the module node SG plus `aws_security_group.node` (8080 from ALB SG); `create_security_group = false`
    - `jenkins-ci` user and `jenkins-deployer` role (1 h sessions; ECR also allows `DescribeImages`/`ListImages` so the pipeline can check whether a tag exists). No access key in state: run `aws iam create-access-key --user-name jenkins-ci` in Task 10
    - New outputs: `cluster_name`, `cluster_arn`, `cluster_endpoint`, `cluster_certificate_authority_data`, `cluster_version`, `cluster_security_group_id`, `eks_node_security_group_id`, `cluster_oidc_issuer_url`, `oidc_provider_arn`, `node_iam_role_arn`, `kubeconfig_command`, `jenkins_ci_user_name`/`_arn`, `jenkins_deployer_role_arn`
    - AWS CLI v2 (2.38.1) is installed at `C:\Program Files\Amazon\AWSCLIV2`, but the v1 MSI (`C:\Program Files\Amazon\AWSCLI\bin`) comes first on PATH. Move v2 up or uninstall v1
    - Adds about $140/mo (control plane $73, nodes $60.74, EBS $3.20, KMS $1, logs); running total about $220/mo
  - Details: task-06-eks-cluster-access.md

- [x] 7. Task 7 - IRSA roles and managed add-ons
  - Depends on: Task 6
  - Create/modify `terraform/infra/irsa.tf`, `eks.tf` (addons), `outputs.tf`
  - IRSA roles scoped to OIDC `sub`/`aud`: EBS CSI (`kube-system:ebs-csi-controller-sa`), LBC (`kube-system:aws-load-balancer-controller`), log-sink (`portfolio:log-sink`, inline logs policy on one log group)
  - IRSA trust uses the `oidc_provider_arn` output from Task 6
  - `aws_cloudwatch_log_group` `/eks/<name>/portfolio-nginx`, 7-day retention
  - Add-ons: vpc-cni, kube-proxy and coredns already exist from Task 6; add aws-ebs-csi-driver (with the EBS CSI IRSA role ARN) and metrics-server to the same `addons` map in `eks.tf`; optionally pin add-on versions
  - Test: `aws eks describe-addon --cluster-name <n> --addon-name <a>` shows ACTIVE for all five add-ons (vpc-cni, kube-proxy, coredns, aws-ebs-csi-driver, metrics-server); `kubectl top nodes` returns data; trust policy JSON has `sub`/`aud` conditions
  - Requires explicit user confirmation with plan summary and cost before applying.
  - As-built:
    - The infra had been torn down before this task (state held only the ECR repo), so the confirmed apply rebuilt Tasks 3-6 together with Task 7: 86 added, 1 changed. A follow-up plan shows no changes
    - The ECR in-place change came from the local `ecr.tf` (`force_delete = true`, `scan_on_push = false`). This differs from the Task 4 spec, and the user applied it as-is
    - IRSA via `terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts` 6.8.2. Roles `eks-portfolio-dev-ebs-csi` (EBS CSI managed policy), `eks-portfolio-dev-lbc` (LBC policy) and `eks-portfolio-dev-log-sink` (inline policy: CreateLogStream/DescribeLogStreams/PutLogEvents on the one log group only). Each trust has StringEquals on `<issuer>:sub` = `system:serviceaccount:<ns>:<sa>` and `<issuer>:aud` = `sts.amazonaws.com`
    - Log group `/eks/eks-portfolio/portfolio-nginx`, 7 days (`app_log_retention_days`)
    - Add-ons are all ACTIVE and use the latest default versions (not pinned): vpc-cni v1.23.2, kube-proxy v1.37.0, coredns v1.14.7, aws-ebs-csi-driver v1.67.0 (with the ebs-csi IRSA role), metrics-server v0.9.0. `kubectl top nodes` returns data; 2 nodes are Ready, one per AZ
    - New outputs: `ebs_csi_irsa_role_arn`, `lbc_irsa_role_arn`, `log_sink_irsa_role_arn`, `portfolio_nginx_log_group_name`
    - Task 7 adds about $0/mo by itself. The rebuild puts the running total back at about $220/mo
  - Details: task-07-irsa-addons.md

- [x] 8. Task 8 - Platform layer (LBC, StorageClass, log-sink)
  - Depends on: Task 7
  - Prerequisite: AWS CLI v2 must be first on PATH (move `C:\Program Files\Amazon\AWSCLIV2` ahead of `C:\Program Files\Amazon\AWSCLI\bin` or uninstall v1); the helm/kubernetes providers exec `aws eks get-token`
  - Create `terraform/platform/{versions,backend,providers,main,variables,outputs}.tf` reading infra outputs via `terraform_remote_state`: Task 4 values (`vpc_id`, subnets) and Task 6/7 values (`cluster_name`, `cluster_endpoint`, `cluster_certificate_authority_data`, LBC and log-sink IRSA role ARNs); helm/kubernetes providers auth with `aws eks get-token`
  - S3 backend via `backend.hcl`; on Windows/pwsh quote it: `terraform init "-backend-config=backend.hcl"`
  - Helm release `aws-load-balancer-controller` (pinned): clusterName, region, vpcId, replicaCount 2, IRSA-annotated ServiceAccount
  - Create `k8s/platform/{kustomization,namespace,storageclass-gp3,log-sink}.yaml` and generated, gitignored `log-sink-config.env`
  - StorageClass `gp3`: `ebs.csi.aws.com`, encrypted, WaitForFirstConsumer, expandable, Retain
  - `log-sink` StatefulSet: 1 Fluent Bit replica, syslog UDP 5140, outputs to 5Gi gp3 PVC file and CloudWatch Logs, non-root, read-only root FS, probes on `/api/v1/health`
  - Test: `kubectl apply --dry-run=server -k k8s/platform`; LBC pods Ready; PVC Bound with PV zone matching node
  - Test: `echo '<14>test' | nc -u -w1 log-sink.portfolio 5140` appears in `/data` and in CloudWatch
  - Requires explicit user confirmation with plan summary and cost before applying.
  - As-built:
    - `terraform/platform` applied (2 added), state key `platform/terraform.tfstate` in the same bucket. Providers: aws `~> 6.69`, helm `~> 3.3`, kubernetes `~> 3.4` (configured, no resources yet), local `~> 2.9`; `.terraform.lock.hcl` committed, `backend.hcl` local/gitignored (`backend.hcl.example` and `terraform.tfvars.example` committed). Remote state bucket defaults to `eks-portfolio-tfstate-<account_id>-<region>` via `aws_caller_identity` (override with `state_bucket`)
    - Providers exec `aws eks get-token`; `aws_cli_command` (default `aws`) can point at the v2 exe. AWS CLI v1 is still first on the system PATH; this run prepended v2 to `$env:PATH` per session
    - Helm release `aws-load-balancer-controller` chart 3.6.0 / app v3.6.0 in kube-system: clusterName, region, vpcId, 2 replicas (one per node), PDB maxUnavailable 1, SA annotated with `eks-portfolio-dev-lbc`. `atomic`, 600 s timeout
    - `local_file` generates gitignored `k8s/platform/log-sink-config.env` (`CW_REGION`, `LOG_GROUP_NAME`, `LOG_SINK_ROLE_ARN`); `.gitignore` adds `k8s/**/*.env`; `log-sink-config.env.example` committed. Kustomize `configMapGenerator` + `replacements` puts the role ARN into the log-sink SA annotation
    - `k8s/platform`: Namespace `portfolio` with PSA `restricted` enforce/warn/audit; StorageClass `gp3` (ebs.csi.aws.com, encrypted, ext4, WaitForFirstConsumer, expandable, Retain); log-sink SA, Fluent Bit YAML ConfigMap, ClusterIP Service UDP 5140, StatefulSet with `fluent/fluent-bit:5.1.4` (digest-pinned), UID/GID/fsGroup 65532, read-only root FS, drop ALL, RuntimeDefault seccomp, requests 50m/64Mi, limits 200m/128Mi, startup/readiness/liveness on `/api/v1/health` (`health_check: on`), 5Gi gp3 PVC at `/data`
    - Fluent Bit uses a lenient syslog regex parser so that both RFC3164 lines from Nginx and bare `<pri>msg` lines are accepted. The file output writes `/data/nginx-access.log` as JSON lines; CloudWatch output goes to stream `log-sink` in `/eks/eks-portfolio/portfolio-nginx` (`auto_create_group: false`)
    - The server dry-run on a fresh cluster fails for namespaced objects until `portfolio` exists, so apply `namespace.yaml` first (or run the dry-run after the first apply)
    - Beyond the spec: cross-node UDP 5140 was dropped because the eks module node rules only allow TCP and DNS. Added `aws_vpc_security_group_ingress_rule.node_syslog_from_nodes` (UDP 5140, node SG to itself) in `terraform/infra/security_groups.tf` (1 added). Follow-up plans for infra and platform both show no changes
    - Verified: LBC 2/2 Ready; PVC `data-log-sink-0` Bound, PV and EBS volume (gp3, encrypted, 5 GiB) in us-east-1a, same zone as the log-sink node, reclaim Retain; `<14>...` sent via `nc -u -w1 log-sink.portfolio 5140` from both nodes shows up in `/data/nginx-access.log` (read via a temporary read-only pod on the same node, since the image is distroless) and in CloudWatch; from pods, `logs.us-east-1.amazonaws.com` resolves to private endpoint IPs
    - Adds about $0.40/mo (5 GB gp3) plus negligible log ingestion; the retained EBS volume must be deleted by hand at teardown. Running total stays at about $220/mo
  - Details: task-08-platform-lbc-storage-logsink.md

- [x] 9. Task 9 - App manifests and HTTPS Ingress
  - Depends on: Tasks 2, 4, 5, 8
  - Create `k8s/app/{kustomization,serviceaccount,nginx-logging,deployment,service,pdb,hpa,ingress}.yaml`, generated gitignored `k8s/app/ingress-config.env`, `scripts/render-k8s-config.ps1`
  - Deployment: 2 replicas, RollingUpdate maxSurge 1 / maxUnavailable 0, progressDeadline 120s, requests 50m/64Mi, limits 200m/128Mi, `/healthz` probes, restricted securityContext, `/tmp` emptyDir, preferred zone/host anti-affinity, zone topology spread
  - Service ClusterIP 80→8080; PDB `minAvailable: 1`; HPA v2 2-5 replicas, CPU 60%, memory 75%, scale-down window 120s
  - Ingress ALB annotations: internet-facing, target-type ip, 80/443, ssl-redirect, cert ARN, TLS13 policy, group `portfolio`, `/healthz` health check, Terraform SG, `manage-backend-security-group-rules: "false"`; cert ARN and SG ID via kustomize `replacements`
  - Test: server dry-run; apply with the Task 4 image; user adds the CNAME; `scripts/smoke-test.sh https://test.name.vn` passes; `curl -I http://test.name.vn` returns 301; pods in both AZs; logs appear in log-sink
  - Requires explicit user confirmation with plan summary and cost before applying.
  - As-built:
    - AWS CLI v1 is uninstalled; `aws` now resolves to v2 (2.38.1, `C:\Program Files\Amazon\AWSCLIV2\aws.exe`), so PATH no longer needs prepending
    - `scripts/render-k8s-config.ps1` (pwsh 7) reads `terraform -chdir=terraform/infra output -json` and writes gitignored `k8s/app/ingress-config.env` (`ACM_CERTIFICATE_ARN`, `ALB_SECURITY_GROUP_ID`, `ECR_REPOSITORY_URL`) with LF endings and no BOM. It warns if the cert isn't ISSUED
    - `k8s/app/kustomization.yaml`: the `ingress-config` generator is annotated `config.kubernetes.io/local-config`, so it only feeds `replacements` and never reaches the cluster. Replacements fill the Ingress `certificate-arn` and `security-groups` annotations and the image repository (`delimiter: ":"`, `index: 0`). No account IDs are committed. The tag comes from `images: [{name: portfolio, newTag: local}]`; a local build confirmed that `kustomize edit set image portfolio:<sha>` (Task 10) produces `<ecr>/portfolio:<sha>`
    - Deployment `portfolio`: 2 replicas (client-side apply leaves the HPA-managed count alone while this value stays unchanged), RollingUpdate 1/0, progressDeadline 120 s, requests 50m/64Mi, limits 200m/128Mi, `/healthz` readiness (5 s) and liveness probes, UID/GID 101, runAsNonRoot, RuntimeDefault seccomp, no privilege escalation, drop ALL, read-only root FS, `/tmp` emptyDir 64Mi, preferred zone (100) and host (50) anti-affinity, zone spread maxSkew 1 ScheduleAnyway with `matchLabelKeys: [pod-template-hash]`, native `preStop` sleep 10 s, grace period 30 s. Dedicated SA `portfolio` with no token mount
    - `nginx-logging.yaml`: ConfigMap mounted at `/etc/nginx/logging` holding `access_log syslog:server=log-sink.portfolio.svc.cluster.local:5140,facility=local7,tag=nginx,severity=info main;`. The stdout access log stays on. The ConfigMap isn't hashed, so a change to it needs `kubectl rollout restart`
    - Service ClusterIP 80→`http` (8080); PDB minAvailable 1; HPA autoscaling/v2 2-5, CPU 60%, memory 75%, scaleDown window 120 s (metrics show, e.g. cpu 2%, memory 5%)
    - Ingress (class `alb`, host `test.name.vn`): internet-facing, target-type ip, listeners 80/443, ssl-redirect 443, ACM cert, `ELBSecurityPolicy-TLS13-1-2-2021-06`, group `portfolio`, health check `/healthz` on traffic-port (10 s interval, 2 healthy, 200), Terraform ALB SG `security-groups`, `manage-backend-security-group-rules: "false"`, deregistration delay 30 s
    - Beyond the spec: `k8s/platform/namespace.yaml` adds the label `elbv2.k8s.aws/pod-readiness-gate-inject: enabled`. The LBC injects an ALB target-health readiness gate (`READINESS GATES 1/1`), so rollouts wait for the ALB to report new pods healthy. Gates only show up on pods created after the TargetGroupBinding exists, so the first pods needed one `kubectl rollout restart`. Re-applying `k8s/platform` left log-sink unchanged (generation 1)
    - Applied after confirmation: `kubectl apply -k k8s/platform` (namespace label), then `kubectl apply -k k8s/app` with ECR image `portfolio:local`. The server dry-run passed with no PSA `restricted` warnings
    - ALB `k8s-portfolio-471bb54941-1675735590.us-east-1.elb.amazonaws.com`: internet-facing, us-east-1a and us-east-1b, SG `<alb sg>` only, HTTPS:443 with the TLS13 policy, HTTP:80 → 301 to `https://test.name.vn:443/`. The user added the CNAME `test.name.vn` → ALB hostname at Cloudflare (DNS only, not proxied; the A records match the ALB IPs)
    - Verified: `scripts/smoke-test.sh https://test.name.vn` passes all 4 checks (run with Git Bash `C:\Program Files\Git\bin\bash.exe`; plain `bash` on this machine resolves to WSL, which has no distro). `curl -I http://test.name.vn` returns 301. TLS 1.3 works. Both targets are healthy. Pods run one per AZ (us-east-1a, us-east-1b). Requests tagged with a marker show up in CloudWatch `/eks/eks-portfolio/portfolio-nginx` from both pods, which confirms cross-node UDP 5140 to log-sink
    - Adds about $25-30/mo (ALB about $16.40 plus LCU about $5.80 plus 2 public IPv4 about $7.30). Running total about $245-250/mo. At teardown (Task 12), delete the Ingress first and wait for the ALB to go away
  - Details: task-09-app-manifests-ingress.md

- [x] 10. Task 10 - Jenkins and pipeline
  - Depends on: Tasks 1, 2, 6, 9
  - Create `jenkins/Dockerfile` (`jenkins/jenkins:lts-jdk21` + docker CLI, AWS CLI v2, kubectl, kustomize, Node 22), `jenkins/plugins.txt`, `jenkins/docker-compose.yml` (bind `127.0.0.1:8080`, Docker socket mount with host-root warning comment)
  - Create `Jenkinsfile` stages: Checkout (short SHA), Install, Lint & Test (JUnit + coverage), Build Image, Push (assume role, skip if tag exists), Deploy (`kustomize edit set image`, `kubectl apply -k`), Verify Rollout (undo on failure), Smoke Test; `OVERRIDE_IMAGE_TAG` parameter
  - Create `scripts/verify-rollout.sh`
  - Create the jenkins-ci access key outside Terraform: `aws iam create-access-key --user-name jenkins-ci`; store it in Jenkins credentials; the pipeline assumes `jenkins_deployer_role_arn`
  - The EKS public endpoint only allows `admin_cidrs`; Jenkins' egress IP must be in that list (local Jenkins shares the admin IP; update `admin_cidrs` if it changes)
  - jenkins-deployer only has Edit in namespace `portfolio`; the pipeline must not touch cluster-scoped resources
  - Test: green run; a committed text change serves the new SHA; `OVERRIDE_IMAGE_TAG=doesnotexist` stalls, rolls back, build goes red, site stays up
  - Requires explicit user confirmation with plan summary and cost before applying.
  - As-built:
    - `jenkins/Dockerfile`: `jenkins/jenkins:2.580.1-lts-jdk21` (digest-pinned) plus docker CLI 29.9.1 and buildx 0.38.0 (the app Dockerfile needs BuildKit cache mounts), AWS CLI 2.38.1, kubectl 1.37.1, kustomize 5.8.3 and Node 22.23.3. Every download is version-pinned and SHA-256 checked. Builds run on the built-in node (2 executors), so the controller image carries the tools. Setup wizard off
    - `jenkins/plugins.txt` (pinned): configuration-as-code, job-dsl, workflow-aggregator, git, credentials-binding, junit, coverage, timestamper, pipeline-stage-view
    - Beyond the spec: `jenkins/casc.yaml` (JCasC) defines the admin user, global env `AWS_REGION`/`EKS_CLUSTER_NAME`/`APP_URL`, the credentials and the `portfolio` pipeline job (Job DSL, `cpsScm` on `https://github.com/datng17/devops-portfolio.git` `*/main`, `pollSCM H/2 * * * *`, `OVERRIDE_IMAGE_TAG` param). UI changes are overwritten on restart
    - `jenkins/docker-compose.yml`: binds `127.0.0.1:8080` only, `jenkins_home` volume, Docker socket mount with the host-root warning comment, `group_add` `DOCKER_GID` (default 0 on Docker Desktop). Credentials come in as Docker secrets from gitignored `jenkins/secrets/` (`jenkins_admin_password`, `jenkins_ci_access_key_id`, `jenkins_ci_secret_access_key`, `jenkins_deployer_role_arn`, `ingress_config_env`)
    - Beyond the spec: `scripts/render-jenkins-secrets.ps1` (pwsh 7) writes those secret files from `terraform output` and `render-k8s-config.ps1`, and generates the admin password once. With `-CreateAccessKey` it runs `aws iam create-access-key --user-name jenkins-ci` and writes the key straight to disk without printing it (refuses if the user already has 2 keys). The key was created this way: jenkins-ci has 1 active key, outside Terraform state
    - `Jenkinsfile` stages: Checkout (7-char short SHA, validates `OVERRIDE_IMAGE_TAG`, installs `ingress-config.env` from secret file `portfolio-ingress-config`), Install (`npm ci`), Lint & Test (`npm run lint`, `test:ci` with `jest-junit` → JUnit, Cobertura → `recordCoverage`), Build Image (OCI revision label), Push, Deploy, Verify Rollout, Smoke Test. Install/Test/Build/Push are skipped when `OVERRIDE_IMAGE_TAG` is set. `disableConcurrentBuilds`, 30 min timeout
    - AWS auth: a per-build AWS config in `<workspace>@tmp` where profile `deployer` assumes `jenkins_deployer_role_arn` with the jenkins-ci key as source profile (session `jenkins-build-<n>`). No `AWS_ACCESS_KEY_ID` in the environment, so every aws/kubectl call runs as the role. The log prints the caller ARN with the account masked. `post { always }` removes the temp AWS/docker/kube config, the CLI cache, `ingress-config.env`, reverts `kustomization.yaml` and removes the local image
    - Push checks `aws ecr describe-images` first and skips the push if the tag exists (IMMUTABLE tags); any error other than `ImageNotFoundException` fails the stage
    - Deploy writes a per-build kubeconfig (`aws eks update-kubeconfig`), records the live Deployment revision, runs `kustomize edit set image portfolio:<tag>` (the ECR repo is filled in by the Task 9 replacements), server dry-run, then `kubectl apply -k k8s/app`. Only namespaced objects in `portfolio` are touched
    - `scripts/verify-rollout.sh`: `kubectl rollout status` (the Deployment's 120 s progress deadline ends a bad rollout), checks the running image equals `EXPECTED_IMAGE`; on failure prints deployment/RS/pod/event diagnostics, `rollout undo --to-revision=<previous>`, waits for it, exits 1 (2 if the undo fails too)
    - The EKS public endpoint allowed Jenkins without changes: local Jenkins egresses from the admin IP already in `admin_cidrs`
    - Verified (Jenkins builds): #1 failed before the job pointed at the GitHub repo (`file:///repo` had no Jenkinsfile); #2 `a8c2cb0` green (first pipeline deploy); #3 `166f744` green, the text change in `Main.tsx` (`DevOps` → `DevOps Engineer`); the live `main.<hash>.js` contains `DevOps Engineer`; #4 `18cca64` green (4/4 tests, JUnit + coverage recorded, push, rollout to revision 5, smoke 4/4, caller `assumed-role/jenkins-deployer/jenkins-build-4`); #5 `OVERRIDE_IMAGE_TAG=doesnotexist`: Install..Push skipped, new pod `ImagePullBackOff`, progress deadline exceeded after about 2 min, undo 6 → 5 (now revision 7, image `18cca64`), build FAILURE, Smoke Test skipped. Afterwards the Deployment is 2/2 on `18cca64` and `https://test.name.vn/healthz` returns `ok`. Availability during #5 rests on `maxUnavailable: 0` (old ReplicaSet kept 2 ready pods); no curl loop was recorded during that run (Task 11 drills cover it)
    - Open: build #6 (`f058f4b`, the latest `main`) fails at Install because commit `6113a7e` ("refresh package-lock.json") left `package-lock.json` out of sync with `package.json` (`npm ci` reports @mui/material, @emotion/*, @fortawesome/*, sass etc. missing). The pipeline stopped before Deploy, so the cluster stayed on `18cca64`. Fix: run `npm install`, commit the lock file, push. `f058f4b` also adds `src/__tests__/tmp-portfolio-smoke.test.tsx`, which looks temporary
    - Adds about $0/mo in AWS (Jenkins runs locally; ECR storage for a few images is cents). Running total stays at about $245-250/mo. At teardown, delete the jenkins-ci access key before `terraform destroy`
  - Details: task-10-jenkins-pipeline.md

- [x] 11. Task 11 - Resilience and HPA verification
  - Depends on: Task 9
  - Create `k8s/tests/k6-load.yaml`: pinned `grafana/k6` Job with ConfigMap script ramping VUs against `http://portfolio.portfolio.svc.cluster.local` for about 5 minutes
  - Create `scripts/hpa-load-test.sh`: start the Job, watch HPA and pods, clean up
  - Document drills in `docs/deployment-guide.md` (pod delete, cordon/drain one AZ, rolling update under load), each with a curl loop
  - Test: HPA scales 2 → 5 → 2; zero non-200 responses during drills
  - Requires explicit user confirmation with plan summary and cost before applying.
  - As-built:
    - Prerequisite fixed (commit `2f8d836`): `package-lock.json` re-synced, and the temp test `src/__tests__/tmp-portfolio-smoke.test.tsx` removed (it imported `../content/site-content` and `../ui/PortfolioPage`, which don't exist in `src/`, so Lint & Test would also have failed). Jenkins #7 went green and deployed `2f8d836`
    - `k8s/tests/k6-load.yaml`: ConfigMap `k6-load-script` plus Job `k6-load`, image `grafana/k6:1.8.2` (digest-pinned). Stages 30s→20, 30s→40, 3m@40, 1m→0 VUs, no think time, `noConnectionReuse` (kube-proxy balances per connection), batch of `/`, `/healthz` and a deep link against `http://portfolio.portfolio.svc.cluster.local`. Thresholds `http_req_failed<1%`, `checks>99%`. PSA restricted: UID 12345, drop ALL, RuntimeDefault, read-only root FS, `/tmp` emptyDir. requests 500m/128Mi, `activeDeadlineSeconds` 600, `ttlSecondsAfterFinished` 1800
    - `scripts/hpa-load-test.sh`: deletes any leftover Job, applies it, samples HPA current/desired/ready, CPU and memory % and pods per node every 15 s, prints the k6 summary, waits for minReplicas (timeout 600 s), prints HPA events, and deletes the Job/ConfigMap on exit (trap). Exits 0 only if peak = max, it returned to min and k6 completed
    - Beyond the spec: `scripts/availability-probe.sh <url> [seconds]` is the curl loop used in every drill (fresh connection, 0.2 s interval, 5 s timeout, per-code counts, non-zero exit on any non-200). `scripts/render-evidence-png.ps1` renders `docs/evidence/*.txt` to terminal-style PNGs with System.Drawing and re-masks account IDs/ARNs/SG IDs before drawing
    - `docs/deployment-guide.md`: the probe plus Drills 1-4 (HPA, pod delete, drain us-east-1b, rolling update), each with commands and expected results, plus cleanup. Drill 3 drains 1b because `log-sink-0`'s gp3 volume sits in 1a
    - Drill 1 (HPA): 2 → 4 (t+41 s, CPU 313%) → 5 (t+71 s), held 5 through the load (CPU about 170%). k6 ended at t+340 s and the HPA dropped to 2 at about t+455 s (seen at t+493 s). k6: 810,468 requests, 0 failed, p95 56 ms. External probe during the load: 257/257 200. Fits on 2 nodes with no new capacity
    - Drill 2 (pod delete): replacement Ready with readiness gate 1/1 in about 18 s, 130/130 200
    - Drill 3 (drain 1b): run 1 got 110/113, 3 × `000` over about 15 s. The drain evicted the LBC leader too; the standby took the lease and deregistered the target about 20 s later, after the 10 s preStop had ended. Fix (user-approved, commit `ce64290`, deployed by Jenkins #8): preStop sleep 10 → 30 s, `terminationGracePeriodSeconds` 30 → 45 (this supersedes the Task 9 values). Run 2 got 164/164 (both portfolio pods on 1b, PDB-serialised evictions, about 60 s on one AZ). The LBC leader sat in 1a for that run, so run 3 recreated the failure directly by deleting the LBC leader and a portfolio pod together: deregistration 20 s later, 144/144. Node uncordoned after each run
    - Drill 4 (rolling update): Jenkins #7 (`18cca64` → `2f8d836`) 945/945 200 over 20 min; Jenkins #8 (`2f8d836` → `ce64290`) 766/766 200 over 15 min. The k6 load was not running during these rollouts, so a rollout at 5 replicas under load was not measured separately
    - Evidence: `docs/evidence/drill-1-hpa.{txt,png}`, `drill-2-pod-delete.{txt,png}`, `drill-3-drain-run1.{txt,png}`, `drill-3-drain-run2.{txt,png}`, `drill-3-drain-run3-lbc-failover.{txt,png}`, `drill-4-rolling-update.{txt,png}`, with a "Resilience evidence" section in `README.md`. Account IDs, ARNs and SG IDs are masked (grep clean). The PNGs are rendered from the captured output, not window screenshots
    - Clean-up verified: no k6 Job/ConfigMap left, both nodes Ready and schedulable. Final state: portfolio 2/2 on `ce64290`, one pod per AZ (1a, 1b), HPA 2 at CPU 2%. Zone spread is preferred only, so after a rollout both pods can end up in one AZ (Jenkins #8 put both in 1b)
    - Adds about $0/mo (a few minutes of in-cluster load, negligible ALB LCU and data transfer). Running total stays at about $245-250/mo
  - Details: task-11-resilience-hpa-tests.md

- [x] 12. Task 12 - Deployment guide, cost validation, teardown
  - Depends on: all previous tasks
  - Create `docs/deployment-guide.md`: prerequisites, ordered commands (bootstrap → infra with ACM two-phase → platform → k8s/platform → first deploy → Jenkins), verification commands, cost table and break-even math, interview talking points
  - Windows commands in the guide must quote `-backend-config`: `terraform init "-backend-config=backend.hcl"`
  - Cost table baseline: about $220/mo running (NAT + EIP ~$36.50, EKS control plane $73, 2× t3.medium ~$60.74, EBS, KMS $1, logs), plus ALB and endpoints from later tasks
  - Create `scripts/teardown.sh` with a confirmation prompt: delete Ingress and wait for ALB removal, delete app/platform resources and PVCs/PVs/EBS volumes, `terraform destroy` platform then infra, keep the state bucket, check for leftovers
  - State bucket has `prevent_destroy`, so teardown keeps it; removing it is manual: remove the lifecycle block, empty all object versions, then destroy
  - Teardown leftovers check also covers the EKS KMS key (scheduled deletion, not immediate) and the `/aws/eks/<name>/cluster` log group; delete the jenkins-ci access key before `terraform destroy` or the IAM user deletion fails
  - Test: after teardown, no ALBs, ENIs or EBS volumes tagged for the cluster remain
  - Requires explicit user confirmation with plan summary and cost before applying.
  - Details: task-12-guide-cost-teardown.md

## Notes

- No tasks are optional.
- Ordering follows each detail file's Dependencies section. Task 4 is placed after Task 2 because its acceptance test pushes `portfolio:local` to ECR.
- Terraform tasks touching `terraform/infra` are kept in separate waves to avoid shared-file edits and state lock contention.
- Every AWS-mutating step (terraform apply/destroy, helm install, kubectl apply) waits for explicit user confirmation with a plan summary and cost estimate.
- On Windows/pwsh, quote the backend argument: `terraform init "-backend-config=backend.hcl"`. Unquoted, it fails with "No positional arguments are expected".
- Task 6 created the core add-ons (vpc-cni, kube-proxy, coredns) early because eks module v21 does not bootstrap them; Task 7 only adds the remaining add-ons.

## Task Dependency Graph

```json
{
  "waves": [
    { "id": 0, "tasks": ["1.1", "3"] },
    { "id": 1, "tasks": ["1.2", "5"] },
    { "id": 2, "tasks": ["1.3"] },
    { "id": 3, "tasks": ["2"] },
    { "id": 4, "tasks": ["4"] },
    { "id": 5, "tasks": ["6"] },
    { "id": 6, "tasks": ["7"] },
    { "id": 7, "tasks": ["8"] },
    { "id": 8, "tasks": ["9"] },
    { "id": 9, "tasks": ["10"] },
    { "id": 10, "tasks": ["11"] },
    { "id": 11, "tasks": ["12"] }
  ]
}
```
