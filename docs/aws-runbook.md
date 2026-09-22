# AWS Console Runbook — Manual Provision & Deploy

**Stack:** FastAPI (`:8000`) + Nginx (`:80/:443`, rate-limited) + MySQL 8.0 + Jenkins → SonarQube → **ECR** → Docker → EC2 + CloudWatch Agent

**Region baseline:** `us-east-1` (matches `.env.example` `AWS_REGION`)
**Source of truth (code):** GitHub `https://github.com/datng17/devops-portfolio` (public)
**Image registry:** AWS ECR — `<account-id>.dkr.ecr.us-east-1.amazonaws.com/devops-portfolio`
**Constraint scope:** no Java runtime on host, no K8s, no Ansible, no Grafana.

> Replace every `<account-id>` with your 12-digit AWS account ID before use.

---

## PHASE 1 — IAM (identities first; everything downstream references these)

- [ ] **1.1 Customer-managed policy: `cw-agent-least-priv`** — CloudWatch Agent metric + log publishing only
  ```json
  {
    "Version": "2012-10-17",
    "Statement": [
      { "Sid": "CWMetrics", "Effect": "Allow",
        "Action": ["cloudwatch:PutMetricData"], "Resource": "*",
        "Condition": { "StringEquals": { "cloudwatch:namespace": "DevOpsPortfolio" } } },
      { "Sid": "CWLogs", "Effect": "Allow",
        "Action": ["logs:CreateLogGroup", "logs:CreateLogStream",
                   "logs:PutLogEvents", "logs:DescribeLogStreams", "logs:DescribeLogGroups"],
        "Resource": "arn:aws:logs:us-east-1:*:log-group:/devops-portfolio/*" },
      { "Sid": "CWAgentSSMConfig", "Effect": "Allow",
        "Action": ["ssm:GetParameter"],
        "Resource": "arn:aws:ssm:us-east-1:*:parameter/AmazonCloudWatch-*" }
    ]
  }
  ```

- [ ] **1.2 Customer-managed policy: `s3-backup-least-priv`** — `scripts/backup_s3.sh` sync/prune + SNS failure alert
  ```json
  {
    "Version": "2012-10-17",
    "Statement": [
      { "Sid": "BackupBucketList", "Effect": "Allow",
        "Action": ["s3:ListBucket"],
        "Resource": "arn:aws:s3:::my-devops-backups",
        "Condition": { "StringLike": { "s3:prefix": ["mysql/*"] } } },
      { "Sid": "BackupObjectRW", "Effect": "Allow",
        "Action": ["s3:PutObject", "s3:GetObject", "s3:DeleteObject"],
        "Resource": "arn:aws:s3:::my-devops-backups/mysql/*" },
      { "Sid": "BackupAlert", "Effect": "Allow",
        "Action": ["sns:Publish"],
        "Resource": "arn:aws:sns:us-east-1:*:mysql-backup-alerts" }
    ]
  }
  ```

- [ ] **1.3 EC2 instance role: `role-devops-portfolio-ec2`**
  - Trusted entity: `ec2.amazonaws.com`
  - Attach: `cw-agent-least-priv`, `s3-backup-least-priv`
  - Attach (AWS-managed, pull images from ECR): `AmazonEC2ContainerRegistryReadOnly`
  - Attach: `AmazonSSMManagedInstanceCore` (SSM session access, less SSH key sprawl)
  - Instance profile: same name (auto-created)

- [ ] **1.4 Deploy identity: `role-jenkins-deployer`** (or IAM user if Jenkins runs off-AWS)
  - Attach: `AmazonEC2ContainerRegistryPowerUser` (push images to ECR)
  - Inline: `ssm:SendCommand` scoped to the EC2 instance, if using SSM-based remote deploy

> **Note:** GitHub source is public, so no GitHub PAT / deploy key and no extra `ssm:GetParameter` grant is required for the clone.

---

## PHASE 2 — Networking / Security Groups

- [ ] **2.1 VPC:** default VPC (single-node portfolio) or `vpc-devops-portfolio` /16
- [ ] **2.2 Subnet:** 1 public subnet, "Auto-assign public IPv4" = ON
- [ ] **2.3 Internet Gateway** attached; route `0.0.0.0/0` → IGW

- [ ] **2.4 Security Group: `sg-web-edge`** (attached to EC2)

  | Dir | Protocol | Port | Source / Dest | Reason |
  |-----|----------|------|---------------|--------|
  | Inbound | TCP | 80 | `0.0.0.0/0` | Nginx HTTP (redirects to 443) |
  | Inbound | TCP | 443 | `0.0.0.0/0` | Nginx HTTPS |
  | Inbound | TCP | 22 | `<YOUR_IP>/32` | SSH admin only (or use SSM) |
  | Outbound | ALL | ALL | `0.0.0.0/0` | ECR / S3 / CloudWatch / packages |

  > `8000` (FastAPI) and `3306` (MySQL) are **NOT** exposed — internal to the Docker network only, fronted by the rate-limited Nginx reverse proxy.

---

## PHASE 3 — EC2 (compute host)

- [ ] **3.1 Launch instance — Configuration Spec Matrix**

  | Field | Value |
  |-------|-------|
  | Name | `ec2-devops-portfolio-prod` |
  | Region / AZ | `us-east-1` / `us-east-1a` |
  | OS (AMI) | Ubuntu Server 22.04 LTS (x86_64) |
  | Instance type | `t3.small` (2 vCPU / 2 GiB) — app + nginx + mysql co-located; 2GB swap covers `mysqldump` spikes |
  | Root EBS | 30 GiB gp3, encrypted, DeleteOnTermination = Yes |
  | IAM instance profile | `role-devops-portfolio-ec2` (Phase 1.3) |
  | Security group | `sg-web-edge` (Phase 2.4) |
  | Key pair | optional if using SSM; else ed25519 keypair |
  | Metadata (IMDS) | IMDSv2 required (`HttpTokens=required`) |

  > **Sizing note:** `t3.micro` (1 GiB) is viable **only** with the 2GB swap below; `t3.small` recommended because MySQL 8.0 + FastAPI + Nginx co-reside on one node.

- [ ] **3.2** Paste the User-Data script from **Phase 6** into "Advanced → User data".
- [ ] **3.3** Allocate + associate an Elastic IP so DNS/TLS survive restarts.

---

## PHASE 4 — S3 (backup target for `backup_s3.sh`)

- [ ] **4.1 Bucket — Configuration Spec Matrix**

  | Field | Value |
  |-------|-------|
  | Bucket name | `my-devops-backups` (prefix: `mysql/`) |
  | Region | `us-east-1` |
  | Block Public Access | ALL ON |
  | Encryption | SSE-S3 (or SSE-KMS) |
  | Versioning | Enabled |
  | Lifecycle rule | prefix `mysql/` → expire after `RETAIN_DAYS` (7) |

  > Matches `.env.example`: `S3_BUCKET=s3://my-devops-backups/mysql`, `RETAIN_DAYS=7`

- [ ] **4.2** Create SNS topic `mysql-backup-alerts` (ARN used by `backup_s3.sh` `ALERT_SNS_TOPIC`); add an email subscription for failure notifications.

---

## PHASE 5 — CloudWatch (metrics, logs, alarms)

- [ ] **5.1 Pre-create log groups** (agent can auto-create, but set retention explicitly):
  - `/devops-portfolio/nginx/access` (30d)
  - `/devops-portfolio/nginx/error` (30d)
  - `/devops-portfolio/app/fastapi` (30d)
  - `/devops-portfolio/mysql/slow` (14d)
  - `/devops-portfolio/app` (30d) — awslogs docker driver group (prod compose)

  > Values mirror `cloudwatch/amazon-cloudwatch-agent.json` + `docker/docker-compose.prod.yml`.

- [ ] **5.2 Alarms** on namespace `DevOpsPortfolio`:

  | Alarm | Condition | Action |
  |-------|-----------|--------|
  | HighCPU | `cpu_usage_idle` < 15% (5m) | SNS notify |
  | LowMemory | `mem_available_percent` < 10% | SNS notify |
  | RootDiskFull | `disk used_percent(/)` > 85% | SNS notify |
  | SwapThrash | `swap_used_percent` > 60% (10m) | SNS notify |

  > Store agent config in SSM Parameter Store as `AmazonCloudWatch-linux` (referenced by `ssm:GetParameter` in policy 1.1).

---

## PHASE 6 — User-Data (single consolidated bootstrap; runs once at first launch)

```bash
#!/usr/bin/env bash
set -euxo pipefail
export DEBIAN_FRONTEND=noninteractive

# --- 6.1 Base packages: Git, curl, unzip (NO Java installed) -----------------
apt-get update -y
apt-get install -y ca-certificates curl gnupg git unzip

# --- 6.2 2GB swap file (protects mysqldump/pip on low-tier RAM) --------------
if ! swapon --show | grep -q '/swapfile'; then
  fallocate -l 2G /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=2048
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  echo '/swapfile none swap sw 0 0' >> /etc/fstab
  sysctl -w vm.swappiness=10
  echo 'vm.swappiness=10' > /etc/sysctl.d/99-swap.conf
fi

# --- 6.3 Docker Engine + Compose plugin --------------------------------------
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu $(. /etc/os-release; echo $VERSION_CODENAME) stable" \
  > /etc/apt/sources.list.d/docker.list
apt-get update -y
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
systemctl enable --now docker
usermod -aG docker ubuntu

# --- 6.4 AWS CLI v2 (for ECR login + backup_s3.sh sync) ----------------------
curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
unzip -q /tmp/awscliv2.zip -d /tmp && /tmp/aws/install --update && rm -rf /tmp/aws /tmp/awscliv2.zip

# --- 6.5 CloudWatch Agent (reads config from SSM param AmazonCloudWatch-linux)
curl -fsSL https://s3.amazonaws.com/amazoncloudwatch-agent/ubuntu/amd64/latest/amazon-cloudwatch-agent.deb \
  -o /tmp/cwagent.deb
dpkg -i -E /tmp/cwagent.deb && rm -f /tmp/cwagent.deb
/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl \
  -a fetch-config -m ec2 -c ssm:AmazonCloudWatch-linux -s

# --- 6.6 Log dirs referenced by agent config + app volume mounts -------------
mkdir -p /var/log/nginx /var/log/app /var/log/mysql /var/backups/mysql /opt/devops-portfolio

# --- 6.7 Pull deploy repo from GitHub (public HTTPS clone, no credentials) ---
git clone https://github.com/datng17/devops-portfolio.git /opt/devops-portfolio || true

echo "bootstrap complete: docker=$(docker --version) swap=$(swapon --show=NAME --noheadings)"
```

---

## PHASE 7 — Verification (single-line; run after SSH/SSM into host)

- [ ] Swap is active (2GB): `swapon --show && free -h | awk '/Swap/{print $2}'`
- [ ] Docker up + non-root: `docker run --rm hello-world >/dev/null && echo OK`
- [ ] Compose plugin present: `docker compose version`
- [ ] Git installed: `git --version`
- [ ] No Java on host (constraint): `! command -v java && echo "no-java-OK"`
- [ ] Source cloned from GitHub: `test -d /opt/devops-portfolio/.git && git -C /opt/devops-portfolio remote get-url origin`
- [ ] IAM role reachable (IMDSv2): `TOKEN=$(curl -s -X PUT http://169.254.169.254/latest/api/token -H "X-aws-ec2-metadata-token-ttl-seconds: 60"); curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/iam/security-credentials/`
- [ ] S3 backup perms (least-priv): `aws s3 ls s3://my-devops-backups/mysql/ --region us-east-1 && echo S3-OK`
- [ ] ECR login works: `aws ecr get-login-password --region us-east-1 | docker login --username AWS --password-stdin "$(aws sts get-caller-identity --query Account --output text).dkr.ecr.us-east-1.amazonaws.com"`
- [ ] CW agent running: `/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl -a status | grep -q '"status": "running"' && echo CW-OK`
- [ ] CW log groups exist: `aws logs describe-log-groups --log-group-name-prefix /devops-portfolio --region us-east-1 --query 'logGroups[].logGroupName'`
- [ ] Nginx edge reachable: `curl -sf -o /dev/null -w '%{http_code}\n' http://localhost/health`
- [ ] FastAPI internal (via proxy): `curl -sf http://localhost/health/db && echo APP-DB-OK`
- [ ] MySQL not public (must fail): `! timeout 3 bash -c '</dev/tcp/<ELASTIC_IP>/3306' && echo "3306-closed-OK"`
- [ ] App not public (must fail): `! timeout 3 bash -c '</dev/tcp/<ELASTIC_IP>/8000' && echo "8000-closed-OK"`

---

## Registry & Source Split (summary)

| Concern | Location | How it's pulled |
|---------|----------|-----------------|
| Source code | GitHub `datng17/devops-portfolio` (public) | Jenkins `checkout scm`; host `git clone` over HTTPS (Phase 6.7) |
| Container images | AWS ECR `<account-id>.dkr.ecr.us-east-1.amazonaws.com/devops-portfolio` | `aws ecr get-login-password` → `docker login` → `compose pull` |

- Jenkins pushes images using `role-jenkins-deployer` (`AmazonEC2ContainerRegistryPowerUser`).
- EC2 hosts pull images using the instance role (`AmazonEC2ContainerRegistryReadOnly`).
- No GitHub token needed anywhere — the repo is public.
