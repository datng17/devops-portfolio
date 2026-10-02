# DevOps Portfolio — Production-Grade FastAPI on AWS EC2

End-to-end DevOps reference project: a containerized **FastAPI** service behind an
**Nginx** reverse proxy, exposed to the internet through a **Cloudflare Tunnel**
that terminates TLS at the edge with an automatically managed certificate. The app
is backed by **MySQL 8.0**, shipped through a **Jenkins → SonarQube → Docker → AWS
EC2** pipeline, hardened at the OS layer and observed with the **AWS CloudWatch
Agent**.

**Stack:** Python (FastAPI) · Docker + Compose · Nginx (rate limiting + security
headers) · Cloudflare Tunnel (automatic edge TLS) · MySQL 8.0 · Jenkins +
SonarQube · AWS (EC2, VPC, CloudWatch)


![image](/docs/images/background.png)
---

## Architecture Overview

```
                        Internet (HTTPS 443)
                                 │
                        ┌────────▼─────────┐
                        │  Cloudflare edge  │  terminates TLS 1.2/1.3 with an
                        │   (managed cert)  │  auto-renewed managed certificate
                        └────────┬─────────┘
                                 │ encrypted tunnel (outbound-only, no open ports)
                        ┌────────▼─────────┐
                        │    cloudflared    │  Docker container, no host port
                        │  tunnel daemon    │  dials out to Cloudflare, pulls traffic
                        └────────┬─────────┘
                                 │ http://nginx:80  (frontend network)
                        ┌────────▼─────────┐
                        │      Nginx        │  security headers, rate limit
                        │  reverse proxy    │  (req zone) + conn limit — plain HTTP
                        └────────┬─────────┘
                                 │ proxy_pass app:8000  (frontend network)
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
cloudflared↔Nginx↔app; `backend` (`internal: true`) connects app↔MySQL with no
host or outbound exposure. The database publishes **no** host port — only the app
can reach it.

**Edge exposure:** the host publishes **no** inbound ports (no 80/443, no public
IP required). `cloudflared` opens an outbound-only connection to the Cloudflare
edge; Cloudflare terminates TLS with an automatically managed certificate and
routes the public hostname to the internal `http://nginx:80` origin.

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
│   ├── docker-compose.yml   base stack (app + nginx + cloudflared + mysql)
│   └── docker-compose.prod.yml   production overrides
├── nginx/
│   ├── nginx.conf           plain-HTTP origin, rate-limit zones, headers
│   └── app.conf             alt plain-HTTP vhost, proxy, limits
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
| **Firewall** | UFW (or firewalld on RHEL) default-deny inbound; only `22` (SSH) allowed — no inbound `80/443` needed since the Cloudflare Tunnel is outbound-only |
| **Brute-force** | fail2ban `sshd` jail — 3 retries, 1h ban |
| **Kernel (sysctl)** | rp_filter, disable source-route/redirects, `tcp_syncookies`, `log_martians`, ASLR (`randomize_va_space=2`), `kptr_restrict`, `dmesg_restrict`, protected symlinks/hardlinks |
| **Patching** | Unattended security upgrades (`unattended-upgrades` / `dnf-automatic`) |

**Application / edge hardening:**
- **Cloudflare Tunnel** terminates TLS 1.2/1.3 at the edge with an automatically issued and renewed managed certificate — no certificates, private keys, or ACME challenges live on the host, and no inbound ports are opened.
- The origin is never exposed directly: `cloudflared` dials out to Cloudflare, so the host needs no public IP and no inbound `80/443`. Optionally layer Cloudflare WAF, bot management, and Zero Trust Access policies at the edge.
- Nginx (plain HTTP, internal only) still adds `X-Content-Type-Options`, `X-Frame-Options: DENY`, `Referrer-Policy`, and `Content-Security-Policy`, and preserves the real client IP from `CF-Connecting-IP`.
- Rate limiting via `limit_req` (burst) + `limit_conn` per client (edge-side rate limiting available via Cloudflare rules).
- MySQL, the app, and Nginx publish **no** host ports; the DB tier sits on an `internal` Docker network.
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
cp .env.example .env                 # set DB_*, REGISTRY, TAG, CLOUDFLARE_TUNNEL_TOKEN
docker compose -f docker/docker-compose.yml up -d --build
docker compose -f docker/docker-compose.yml logs -f cloudflared   # watch the tunnel connect
```

The stack publishes **no** host ports. Reach the service through the public
hostname configured on the tunnel (`https://<your-hostname>/health`), which
Cloudflare serves over HTTPS automatically. For a local origin smoke test:

```bash
docker compose -f docker/docker-compose.yml exec nginx wget -qO- http://127.0.0.1/health
```

### Set up the Cloudflare Tunnel

Automatic HTTPS comes from Cloudflare — there is no certificate to manage.

1. In the **Cloudflare Zero Trust dashboard** → **Networks → Tunnels**, create a
   tunnel of type **Cloudflared**.
2. Add a **public hostname** (`portfolio.dev`) and set the service to
   `http://nginx:80` — this is the internal origin cloudflared reaches on the
   Compose `frontend` network.
3. Copy the tunnel **token** and set it in `.env` as `CLOUDFLARE_TUNNEL_TOKEN`.
4. Bring the stack up; `cloudflared` dials out to Cloudflare and the hostname
   goes live over HTTPS. No DNS A record, open ports, or public IP are required —
   the tunnel is outbound-only and Cloudflare manages the TLS certificate.

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
Nginx + Cloudflare Tunnel (`cloudflared`) → CloudWatch agent/alarms → push to
trigger the pipeline → enable backup/health cron + logrotate.

See `docs/runbook.md`, `docs/capacity-planning.md` for operational