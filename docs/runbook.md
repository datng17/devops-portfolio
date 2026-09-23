# Operations Runbook

## SOP — Web / App Failure

1. Confirm scope: `curl -I https://test.name.vn/health`. 502/504 = proxy up, backend down; timeout = host/proxy down.
2. Check Nginx: `systemctl status nginx`; `nginx -t`; tail `/var/log/nginx/error.log`.
3. Check app container: `docker compose ps`; `docker compose logs --tail=100 app`; `curl 127.0.0.1:8000/health`.
4. Restart: `docker compose up -d app`. If image is bad, redeploy previous tag: `TAG=<prev> docker compose up -d`.
5. Resource check: run `scripts/sys_diag.py`; review CloudWatch CPU/mem/disk alarms.

## SOP — Reverse Proxy (TLS / Nginx)

1. TLS expiry: `sudo certbot certificates`; renew with `sudo certbot renew`; verify the renewal timer is active.
2. Config error after change: always `nginx -t` before `systemctl reload nginx` (prefer reload over restart).
3. Rate-limit false positives: look for `limiting requests` in `error.log`; tune `rate`/`burst` in `nginx/app.conf`.
4. High 5xx: correlate the CloudWatch 5xx metric filter with app logs — usually the backend, not the proxy.

## SOP — Database Failure

1. Connectivity: from the web host `mysql -h 10.0.2.x -u appuser -p -e "SELECT 1"`. Failure -> check `sg-db`, UFW, service.
2. Service: on the DB host `systemctl status mysql`; tail `/var/log/mysql/error.log`.
3. Disk full (common): `df -h`; purge old binlogs (`PURGE BINARY LOGS BEFORE ...`), rotate/backup, extend the volume.
4. Recovery: restore latest dump with `scripts/db_restore.sh`, then replay binlogs for point-in-time recovery.
5. Replication lag: `SHOW REPLICA STATUS\G` — check `Seconds_Behind_Source`; if a thread stopped, review `Last_Error`, fix, `START REPLICA;`.
6. Backups: verify the last run in `/var/log/db_backup.log` and the object in S3. Test-restore monthly.
