#!/usr/bin/env bash
# Nightly backup of one environment, for cron (see docs/pi-setup.md):
#   0 2 * * * /home/pi/erp/deploy/nightly-backup.sh pi
#
# 1. deploy.sh backup: database, public + private files, site_config.json (holds the
#    encryption key once one exists) and image.env, into BACKUP_DIR/<UTC stamp>/
# 2. checks the archives are readable (gzip -t, tar -t)
# 3. deletes backup folders older than BACKUP_RETENTION_DAYS (env file, default 14)
#
# Logs to deploy/logs/nightly-backup.log. Exits non-zero on any failure, and appends the
# failure to BACKUP_DIR/FAILED.log, which the PC pull script reports.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_NAME="${1:?usage: deploy/nightly-backup.sh <env>}"
set -a; source "$HERE/env/$ENV_NAME.env"; set +a
KEEP="${BACKUP_RETENTION_DAYS:-14}"

mkdir -p "$HERE/logs"
exec >>"$HERE/logs/nightly-backup.log" 2>&1
echo "=== $(date -Is) nightly backup of $ENV_NAME"

fail() {
  echo "FAILED: $*"
  echo "$(date -Is) $ENV_NAME: $*" >> "$BACKUP_DIR/FAILED.log"
  exit 1
}
trap 'fail "line $LINENO: $BASH_COMMAND"' ERR

"$HERE/deploy.sh" backup "$ENV_NAME"

# Newest folder = the one just written (names are UTC stamps, so they sort by time).
dir="$(find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d -name '20*Z' | sort | tail -1)"
[ -n "$dir" ] || fail "no backup folder in $BACKUP_DIR"
gzip -t "$dir"/*-database.sql.gz || fail "database dump corrupt in $dir"
for t in "$dir"/*.tar; do tar -tf "$t" >/dev/null || fail "archive corrupt: $t"; done
grep -q '"db_name"' "$dir/site_config.json" || fail "site_config.json missing in $dir"
echo "verified $dir ($(du -sh "$dir" | cut -f1))"

# Retention: only our stamp-named folders, never anything else in BACKUP_DIR.
find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d -name '20*Z' -mtime +"$KEEP" -print \
  -exec rm -rf {} +
echo "done $(date -Is)"
