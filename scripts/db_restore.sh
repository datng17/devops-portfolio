#!/usr/bin/env bash
# Restore a gzipped MySQL dump into appdb. Prompts before overwriting.
# Usage: MYSQL_ROOT_PASS=... ./db_restore.sh <backup.sql.gz>
set -euo pipefail

FILE="${1:?usage: db_restore.sh <backup.sql.gz>}"
DB="appdb"
USER="root"
PASS="${MYSQL_ROOT_PASS:?set MYSQL_ROOT_PASS}"

echo "[!] Restoring $FILE into $DB (existing data will be overwritten)"
read -rp "Type 'yes' to continue: " ok
[[ "$ok" == "yes" ]] || { echo "aborted"; exit 1; }

gunzip -c "$FILE" | mysql -u "$USER" -p"$PASS" "$DB"
echo "[+] Restore complete"
