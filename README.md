# DevOps Portfolio — Production-Grade FastAPI on AWS EC2

End-to-end DevOps reference project: a containerized **FastAPI** service behind an
**Nginx** TLS reverse proxy, backed by **MySQL 8.0**, shipped through a
**Jenkins → SonarQube → Docker → AWS EC2** pipeline, hardened at the OS layer and
observed with the **AWS CloudWatch Agent**.

**Stack:** Python (FastAPI) · Docker + Compose · Nginx (TLS + rate limiting) ·
MySQL 8.0 · Jenkins + SonarQube · AWS (EC2, VPC, CloudWatch)

> Deliberately excludes Java/Tomcat, Kubernetes, Ansible, and Grafana — the scope
> targets a Linux Systems / DevOps engineer workflow on plain EC2.

---

## Architecture Overview

```
                          Internet (80/443)
                                 │
                        ┌────────▼─────────┐
                        │      Nginx        │  TLS 1.2/1.3, HSTS, security headers
                        │  reverse proxy    │  rate limit (req zone) + conn limit
                        └────────┬─────────┘
                                 │ proxy_pass 127.0.0.1:8000  (frontend network)
                        ┌────────▼─────────┐
                        │   FastAPI (app)   │  uvicorn :8000, /health + /health/db
                        │   Docker container│  no host port published (expose only)
                        └────────┬─────────┘
                                 │ SQLAlchemy  (backend network, internal=true)
                        ┌────────▼─────────┐
                        │    MySQL 8.0      │  prod_db / app_user, no host port
                        │   Docker container│  persisted volume + init schema
                        └───────────────────┘

  CI/CD:  git push ─► Jenkins ─► lint+pytest ─► SonarQube Quality Gate
                        └─► docker build/push (GHCR) ─► SSH deploy to EC2
  Observability: CloudWatch Agent ─► metrics (cpu/mem/disk/swap) + log streams
                        └─► alarms (CPU>80%, Disk>85%) ─► SNS ops-alerts
```

**Network segmentation (Compose):** two bridge networks. `frontend` connects
Nginx↔app; `backend` (`internal: true`) connects app↔MySQL with no host or
outbound exposure. The database publishes **no** host port — only the app can
reach it.

**Health model:** `/health` is a liveness probe (no DB dependency); `/health/db`
is a readiness probe that pings MySQL and returns `503` when it is unreachable.

---

## Folder Structure

```
.                            repository root
├── app/                     FastAPI application
│   ├── main.py              routes: /health, /health/db, /items (GET/POST)
│   ├── db.py                SQLAlchemy engine/session + db_healthy()
│   ├── requirements.txt
│   └── tests/               pytest suite
├── docker/
│   ├── Dockerfile           app image
│   ├── docker-compose.yml   base stack (app + nginx + mysql)
│   └── docker-compose.prod.yml   production overrides
├── nginx/
│   ├── nginx.conf           global config, rate-limit zones
│   └── app.conf             TLS vhost, HSTS, proxy, limits
├── mysql/
│   ├── my.cnf               InnoDB / connection tuning
│   └── init/01-schema.sql   schema + seed
├── scripts/
│   ├── harden.sh            OS hardening (SSH, firewall, fail2ban, sysctl)
│   ├── sys_diag.py          stdlib system diagnostics → JSON
│   ├── aws_alarms.sh        create CloudWatch CPU/Disk alarms
│   ├── db_backup.sh / db_restore.sh / backup_s3.sh / restore_test.sh
│   ├── health_check.py      endpoint probe
│   └── log_rotate.conf
├── cloudwatch/
│   ├── amazon-cloudwatch-agent.json   metrics + log stream config
│   └── alarms.md            alarm threshold reference
├── ci/
│   ├── Jenkinsfile          declarative CI/CD pipeline
│   ├── sonarqube-compose.yml
│   └── docker-compose.ci.yml
├── docs/                    runbook + capacity planning
├── sonar-project.properties
└── .env.example
```

---

## Security Hardening Summary

Applied via `scripts/harden.sh` (idempotent; supports Ubuntu/Debian + RHEL/Amazon Linux):

| Layer | Control |
|-------|---------|
| **SSH** | Key-only auth (`PasswordAuthentication no`), `PermitRootLogin no`, `MaxAuthTries 3`, idle timeout, config validated with `sshd -t` before restart |
| **Accounts** | Dedicated non-root sudo user; password login locked |
| **Firewall** | UFW (or firewalld on RHEL) default-deny inbound; only 22/80/443 allowed |
| **Brute-force** | fail2ban `sshd` jail — 3 retries, 1h ban |
| **Kernel (sysctl)** | rp_filter, disable source-route/redirects, `tcp_syncookies`, `log_martians`, ASLR (`randomize_va_space=2`), `kptr_restrict`, `dmesg_restrict`, protected symlinks/hardlinks |
| **Patching** | Unattended security upgrades (`unattended-upgrades` / `dnf-automatic`) |

**Application / edge hardening:**
- Nginx enforces TLS 1.2/1.3 with a modern cipher suite, HSTS, `X-Content-Type-Options`, `X-Frame-Options: DENY`, and `Referrer-Policy`.
- Rate limiting via `limit_req` (burst) + `limit_conn` per client.
- MySQL and the app publish **no** host ports; the DB tier sits on an `internal` Docker network.
- Parameterized SQL (SQLAlchemy `text()` with bind params) — no string interpolation.
- Pydantic input validation on write endpoints (`name` length bounds).
- CI enforces a SonarQube **Quality Gate** that aborts the pipeline on failure.

---

## Quickstart

### Local (app only)

```bash
python3 -m venv .venv
. .venv/bin/activate                 # Windows: .venv\Scripts\Activate.ps1
pip install -r app/requirements.txt
PYTHONPATH=. pytest app/tests
PYTHONPATH=. uvicorn app.main:app --reload    # http://127.0.0.1:8000
```

`GET /health` works with no database. `/health/db` and `/items` need MySQL.

### Full stack (Docker Compose)

```bash
cp .env.example .env                 # set DB_*, REGISTRY, TAG
docker compose -f docker/docker-compose.yml up -d --build
curl -fsS http://127.0.0.1/health    # via nginx
```

### Harden an EC2 host

```bash
sudo ADMIN_USER=deploy SSH_PORT=22 bash scripts/harden.sh
# paste the deploy public key into /home/deploy/.ssh/authorized_keys,
# then verify key login in a NEW session before closing the current one.
```

### Install CloudWatch monitoring

```bash
# 1) Agent config (EC2 role needs CloudWatchAgentServerPolicy)
sudo cp cloudwatch/amazon-cloudwatch-agent.json \
  /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json
sudo /opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl \
  -a fetch-config -m ec2 -s \
  -c file:/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json

# 2) Alarms (CPU > 80%, Disk > 85%)
INSTANCE_ID=i-0abc123 \
SNS_TOPIC_ARN=arn:aws:sns:us-east-1:1234567890:ops-alerts \
AWS_REGION=us-east-1 bash scripts/aws_alarms.sh
```

### CI/CD pipeline

`ci/Jenkinsfile` runs: **checkout → lint + pytest (coverage) → SonarQube scan →
Quality Gate (abort on fail) → Docker build/tag → push (GHCR) → deploy staging →
manual approval → deploy production (`main` only)**. Post-build prunes dangling
images.

### Bring-up order

VPC/subnets/SGs → EC2 hosts → `harden.sh` → MySQL → Jenkins/SonarQube → web host +
Nginx + TLS → CloudWatch agent/alarms → push to trigger the pipeline → enable
backup/health cron + logrotate.

See `docs/runbook.md`, `docs/capacity-planning.md` for operational