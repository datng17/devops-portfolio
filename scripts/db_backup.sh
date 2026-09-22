#!/usr/bin/env bash
# Automated MySQL dump -> gzip -> S3 with local retention.
# Usage: MYSQL_BACKUP_PASS=... ./db_backup.sh
set -euo pipefail

DB="appdb"
USER="backup"
PASS="${MYSQL_BACKUP_PASS:?set MYSQL_BACKUP_PASS}"
STAMP="$(date +%F_%H%M%S)"
DIR="/var/backups/mysql"
FILE="$DIR/${DB}_${STAMP}.sql.gz"
S3_BUCKET="${S3_BUCKET:-s3://my-devops-backups/mysql}"
RETAIN_DAYS="${RETAIN_DAYS:-7}"

mkdir -p "$DIR"

echo "[*] Dumping $DB -> $FILE"
mysqldump --single-transaction --quick --routines --triggers \
  -u "$USER" -p"$PASS" "$DB" | gzip > "$FILE"

echo "[*] Uploading to $S3_BUCKET"
aws s3 cp "$FILE" "$S3_BUCKET/" --only-show-errors

echo "[*] Pruning local backups older than ${RETAIN_DAYS} days"
find "$DIR" -name "${DB}_*.sql.gz" -mtime +"$RETAIN_DAYS" -delete

echo "[+] Backup complete: $(basename "$FILE")"
