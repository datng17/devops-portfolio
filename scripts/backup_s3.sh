#!/usr/bin/env bash
#
# backup_s3.sh — MySQL logical backup -> gzip -> S3, with local retention,
#                log rotation, and failure alerting via trap.
#
# Env:
#   MYSQL_BACKUP_PASS  (required)  password for the 'backup' user
#   DB_NAME            (default appdb)
#   BACKUP_DIR         (default /var/backups/mysql)
#   S3_BUCKET          (default s3://my-devops-backups/mysql)
#   RETAIN_DAYS        (default 7)   local + S3 retention window
#   LOG_FILE           (default /var/log/mysql/backup_s3.log)
#   ALERT_SNS_TOPIC    (optional)    SNS topic ARN for CloudWatch/SNS alert
#   AWS_REGION         (default us-east-1)
#
set -euo pipefail

DB_NAME="${DB_NAME:-appdb}"
DB_USER="backup"
DB_PASS="${MYSQL_BACKUP_PASS:?set MYSQL_BACKUP_PASS}"
BACKUP_DIR="${BACKUP_DIR:-/var/backups/mysql}"
S3_BUCKET="${S3_BUCKET:-s3://my-devops-backups/mysql}"
RETAIN_DAYS="${RETAIN_DAYS:-7}"
LOG_FILE="${LOG_FILE:-/var/log/mysql/backup_s3.log}"
ALERT_SNS_TOPIC="${ALERT_SNS_TOPIC:-}"
AWS_REGION="${AWS_REGION:-us-east-1}"

STAMP="$(date +%F_%H%M%S)"
HOST="$(hostname -s)"
DUMP_FILE="${BACKUP_DIR}/${DB_NAME}_${STAMP}.sql.gz"

mkdir -p "$BACKUP_DIR" "$(dirname "$LOG_FILE")"

log() { printf '%s [%s] %s\n' "$(date '+%F %T')" "$1" "${*:2}" | tee -a "$LOG_FILE" >&2; }

alert() {
  local msg="$1"
  log ERROR "$msg"
  if [[ -n "$ALERT_SNS_TOPIC" ]]; then
    aws sns publish \
      --region "$AWS_REGION" \
      --topic-arn "$ALERT_SNS_TOPIC" \
      --subject "MySQL backup FAILED on ${HOST}" \
      --message "$msg" >/dev/null 2>&1 || log ERROR "SNS publish failed"
  fi
}

# Fire on any error/interrupt. $LINENO/$BASH_COMMAND identify the failing step.
on_error() {
  local ec=$?
  alert "Backup failed (exit=${ec}) at line ${BASH_LINENO[0]} running: ${BASH_COMMAND}"
  # Remove partial artifact so it never gets mistaken for a valid backup.
  [[ -f "$DUMP_FILE" ]] && rm -f "$DUMP_FILE"
  exit "$ec"
}
trap on_error ERR INT TERM

# --- Log rotation: keep 30 compressed generations of this script's log ------
rotate_log() {
  local max_bytes=$((10 * 1024 * 1024))   # 10 MiB
  if [[ -f "$LOG_FILE" && "$(stat -c%s "$LOG_FILE")" -ge "$max_bytes" ]]; then
    mv "$LOG_FILE" "${LOG_FILE}.${STAMP}"
    gzip -f "${LOG_FILE}.${STAMP}"
    : > "$LOG_FILE"
    ls -1t "${LOG_FILE}".*.gz 2>/dev/null | tail -n +31 | xargs -r rm -f
  fi
}
rotate_log

# --- Dump (consistent, InnoDB-safe) -----------------------------------------
log INFO "Starting backup of '${DB_NAME}' -> ${DUMP_FILE}"
mysqldump \
  --user="$DB_USER" --password="$DB_PASS" \
  --single-transaction --quick --routines --triggers --events \
  --set-gtid-purged=OFF --no-tablespaces \
  "$DB_NAME" | gzip -c > "$DUMP_FILE"

# Guard against a zero-byte / truncated dump.
if [[ ! -s "$DUMP_FILE" ]] || ! gzip -t "$DUMP_FILE"; then
  false   # triggers ERR trap
fi
SIZE="$(du -h "$DUMP_FILE" | cut -f1)"
log INFO "Dump complete (${SIZE})"

# --- Upload to S3 -----------------------------------------------------------
log INFO "Syncing local backups -> ${S3_BUCKET}"
aws s3 sync "$BACKUP_DIR/" "${S3_BUCKET}/" \
  --region "$AWS_REGION" \
  --exclude "*" --include "${DB_NAME}_*.sql.gz" \
  --only-show-errors
log INFO "Upload complete"

# --- Retention: prune local + S3 objects older than RETAIN_DAYS -------------
log INFO "Pruning backups older than ${RETAIN_DAYS} day(s)"
find "$BACKUP_DIR" -name "${DB_NAME}_*.sql.gz" -mtime +"$RETAIN_DAYS" -delete

CUTOFF="$(date -u -d "-${RETAIN_DAYS} days" +%s)"
aws s3 ls "${S3_BUCKET}/" --region "$AWS_REGION" | while read -r d t _ key; do
  [[ "$key" == ${DB_NAME}_*.sql.gz ]] || continue
  obj_epoch="$(date -u -d "${d} ${t}" +%s)"
  if (( obj_epoch < CUTOFF )); then
    aws s3 rm "${S3_BUCKET}/${key}" --region "$AWS_REGION" --only-show-errors
    log INFO "Pruned s3 object ${key}"
  fi
done

log INFO "Backup finished OK: $(basename "$DUMP_FILE")"
trap - ERR INT TERM
exit 0
