# Operations Runbook

## SOP — Web / App Failure

1. Confirm scope: `curl -I https://portfolio.dev/health`. 502/504 = edge/origin up, backend down; timeout/1033 = tunnel down.
2. Check the tunnel: `docker compose logs --tail=100 cloudflared` (look for a healthy "Registered tunnel connection"); confirm the tunnel is **Healthy** in the Cloudflare Zero Trust dashboard.
3. Check Nginx (internal origin): `docker compose exec nginx nginx -t`; `docker compose exec nginx wget -qO- http://127.0.0.1/health`; tail `/var/log/nginx/error.log`.
4. Check app container: `docker compose ps`; `docker compose logs --tail=100 app`; `docker compose exec app curl 127.0.0.1:8000/health`.
5. Restart: `docker compose up -d app`. If image is bad, redeploy previous tag: `TAG=<prev> docker compose up -d`.
6. Resource check: run `scripts/sys_diag.py`; review CloudWatch CPU/mem/disk alarms.

## SOP — Edge / Tunnel (Cloudflare) + Nginx origin

1. TLS: certificates are issued and renewed automatically by Cloudflare — there is nothing to renew on the host. If HTTPS fails, check the hostname's status in the Cloudflare dashboard, not the host.
2. Tunnel down (Cloudflare error 1033 / "no healthy origins"): `docker compose restart cloudflared`; verify `CLOUDFLARE_TUNNEL_TOKEN` is set and the public hostname maps to `http://nginx:80`; confirm egress to Cloudflare is allowed (outbound 443/7844).
3. Config error after an Nginx change: always `docker compose exec nginx nginx -t` before `docker compose restart nginx` (prefer reload over restart).
4. Rate-limit false positives: look for `limiting requests` in `error.log`; tune `rate`/`burst` in `nginx/nginx.conf` (or add a Cloudflare rate-limiting rule at the edge).
5. High 5xx: correlate the CloudWatch 5xx metric filter with app logs — usually the backend, not the proxy or tunnel.

## SOP — Database Failure

1. Connectivity: from the web host `mysql -h 10.0.2.x -u appuser -p -e "SELECT 1"`. Failure -> check `sg-db`, UFW, service.
2. Service: on the DB host `systemctl status mysql`; tail `/var/log/mysql/error.log`.
3. Disk full (common): `df -h`; purge old binlogs (`PURGE BINARY LOGS BEFORE ...`), rotate/backup, extend the volume.
4. Recovery: restore latest dump with `scripts/db_restore.sh`, then replay binlogs for point-in-time recovery.
5. Replication lag: `SHOW REPLICA STATUS\G` — check `Seconds_Behind_Source`; if a thread stopped, review `Last_Error`, fix, `START REPLICA;`.
6. Backups: verify the last run in `/var/log/db_backup.log` and the object in S3. Test-restore monthly.
