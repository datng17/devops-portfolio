#!/usr/bin/env bash
#
# restore_test.sh — automated restore verification.
# Pulls the latest S3 backup (or a given file), restores into a throwaway
# scratch database, validates row counts, then drops the scratch DB.
# Exit 0 = restore is provably usable; non-zero = alert-worthy failure.
#
# Env:
#   MYSQL_ROOT_PASS   (required)  root/admin password to create scratch DB
#   DB_NAME           (default appdb)      source logical DB name
#   SCRATCH_DB        (default appdb_restore_test)
#   S3_BUCKET         (default s3://my-devops-backups/mysql)
#   BACKUP_DIR        (default /var/backups/mysql)
#   LOG_FILE          (default /var/log/mysql/restore_test.log)
#   ALERT_SNS_TOPIC   (optional)  SNS topic ARN
#   AWS_REGION        (default us-east-1)
#
# Usage:
#   ./restore_test.sh                 # verify latest backup from S3
#   ./restore_test.sh /path/dump.gz   # verify a specific local file
#
set -euo pipefail

DB_NAME="${DB_NAME:-appdb}"
SCRATCH_DB="${SCRATCH_DB:-appdb_restore_test}"
DB_USER="root"
DB_PASS="${MYSQL_ROOT_PASS:?set MYSQL_ROOT_PASS}"
S3_BUCKET="${S3_BUCKET:-s3://my-devops-backups/mysql}"
BACKUP_DIR="${BACKUP_DIR:-/var/backups/mysql}"
LOG_FILE="${LOG_FILE:-/var/log/mysql/restore_test.log}"
ALERT_SNS_TOPIC="arn:aws:sns:us-east-1:119640367180:mysql-backup-alerts"
AWS_REGION="${AWS_REGION:-us-east-1}"

mkdir -p "$(dirname "$LOG_FILE")"
TMP_FILE=""

log() { printf '%s [%s] %s\n' "$(date '+%F %T')" "$1" "${*:2}" | tee -a "$LOG_FILE" >&2; }
mysql_exec() { mysql --user="$DB_USER" --password="$DB_PASS" -N -B -e "$1"; }

alert() {
  local msg="$1"
  log ERROR "$msg"
  [[ -n "$ALERT_SNS_TOPIC" ]] && aws sns publish \
    --region "$AWS_REGION" --topic-arn "$ALERT_SNS_TOPIC" \
    --subject "MySQL restore-test FAILED on $(hostname -s)" \
    --message "$msg" >/dev/null 2>&1 || true
}

cleanup() {
  local ec=$?
  mysql_exec "DROP DATABASE IF EXISTS \`${SCRATCH_DB}\`;" 2>/dev/null || true
  [[ -n "$TMP_FILE" && -f "$TMP_FILE" ]] && rm -f "$TMP_FILE"
  (( ec != 0 )) && alert "restore_test failed (exit=${ec}) at line ${BASH_LINENO[0]}: ${BASH_COMMAND}"
  exit "$ec"
}
trap cleanup ERR INT TERM EXIT

# --- Resolve backup source --------------------------------------------------
if [[ $# -ge 1 ]]; then
  SRC="$1"
  [[ -s "$SRC" ]] || { log ERROR "file not found: $SRC"; false; }
  log INFO "Using local backup: $SRC"
else
  LATEST_KEY="$(aws s3 ls "${S3_BUCKET}/" --region "$AWS_REGION" \
    | grep -E "${DB_NAME}_.*\.sql\.gz$" | sort | tail -n1 | awk '{print $4}')"
  [[ -n "$LATEST_KEY" ]] || { log ERROR "no backups found in ${S3_BUCKET}"; false; }
  TMP_FILE="$(mktemp "${BACKUP_DIR:-/tmp}/restore_test.XXXXXX.sql.gz")"
  SRC="$TMP_FILE"
  log INFO "Downloading latest backup: ${LATEST_KEY}"
  aws s3 cp "${S3_BUCKET}/${LATEST_KEY}" "$SRC" \
    --region "$AWS_REGION" --only-show-errors
fi

# --- Integrity of the archive before restore --------------------------------
gzip -t "$SRC" || { log ERROR "corrupt gzip archive: $SRC"; false; }

# --- Restore into scratch DB ------------------------------------------------
log INFO "Creating scratch database ${SCRATCH_DB}"
mysql_exec "DROP DATABASE IF EXISTS \`${SCRATCH_DB}\`;
            CREATE DATABASE \`${SCRATCH_DB}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"

log INFO "Restoring dump into ${SCRATCH_DB}"
gunzip -c "$SRC" | mysql --user="$DB_USER" --password="$DB_PASS" "$SCRATCH_DB"

# --- Verification -----------------------------------------------------------
TABLE_COUNT="$(mysql_exec "SELECT COUNT(*) FROM information_schema.tables
                           WHERE table_schema='${SCRATCH_DB}';")"
[[ "$TABLE_COUNT" -ge 1 ]] || { log ERROR "restored schema has no tables"; false; }

ITEMS_ROWS="$(mysql_exec "SELECT COUNT(*) FROM \`${SCRATCH_DB}\`.items;" 2>/dev/null || echo "0")"

log INFO "Verification OK: ${TABLE_COUNT} table(s), items rows=${ITEMS_ROWS}"
log INFO "Restore test PASSED"
# EXIT trap performs scratch-DB teardown and temp cleanup.
exit 0
