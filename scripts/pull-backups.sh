#!/usr/bin/env bash
# Pull the Pi's backups to this PC (see docs/pi-setup.md, "Backups").
# The PC is often off at night, so it pulls whenever it runs (cron + at boot); the Pi keeps
# 14 days, the PC keeps RETENTION_DAYS. Install a copy outside the repo and schedule it:
#
#   install -m 755 scripts/pull-backups.sh ~/my-scripts/erp-pull-backups.sh
#   crontab: 0 23 * * 1-5 $HOME/my-scripts/erp-pull-backups.sh
#            @reboot sleep 120 && $HOME/my-scripts/erp-pull-backups.sh
#
# Settings can be overridden in ~/.config/erp-pull-backups.env (same variable names).
set -euo pipefail

PI_USER="pi"
PI_LAN_HOST="raspberrypi.local"
PI_NETBIRD_HOST=""            # Netbird IP or name of the Pi (netbird status -d); empty = LAN only
SSH_KEY="$HOME/.ssh/erpnext_backup_key"
REMOTE_DIR="/mnt/backup/erp-backups"
LOCAL_DIR="$HOME/erp-backups-from-pi"
RETENTION_DAYS=60
CONF="$HOME/.config/erp-pull-backups.env"
[ -f "$CONF" ] && source "$CONF"

mkdir -p "$LOCAL_DIR/logs"
exec > >(tee -a "$LOCAL_DIR/logs/pull.log") 2>&1
echo "=== $(date -Is) pull started"

ssh_ok() { ssh -i "$SSH_KEY" -o BatchMode=yes -o ConnectTimeout="$2" "$PI_USER@$1" true 2>/dev/null; }

WE_CONNECTED=false
if ssh_ok "$PI_LAN_HOST" 5; then
  PI="$PI_LAN_HOST"; echo "Pi reachable on the LAN"
elif [ -n "$PI_NETBIRD_HOST" ]; then
  if ! netbird status | grep -q "Daemon status: Connected"; then
    echo "connecting Netbird"; netbird up; WE_CONNECTED=true; sleep 5
  fi
  ssh_ok "$PI_NETBIRD_HOST" 10 || { echo "Pi not reachable over Netbird either"; $WE_CONNECTED && netbird down; exit 1; }
  PI="$PI_NETBIRD_HOST"; echo "Pi reachable over Netbird"
else
  echo "Pi not reachable on the LAN and PI_NETBIRD_HOST is not set"; exit 1
fi

# No --delete: the PC keeps a longer history than the Pi.
rsync -a --info=stats1 -e "ssh -i $SSH_KEY -o BatchMode=yes" "$PI_USER@$PI:$REMOTE_DIR/" "$LOCAL_DIR/"
$WE_CONNECTED && { echo "disconnecting Netbird"; netbird down; }

# Check the newest backup arrived intact.
newest="$(find "$LOCAL_DIR" -mindepth 1 -maxdepth 1 -type d -name '20*Z' | sort | tail -1)"
if [ -z "$newest" ]; then
  echo "WARNING: no backups in $LOCAL_DIR"
else
  gzip -t "$newest"/*-database.sql.gz && echo "newest backup OK: $(basename "$newest")"
  age_h=$(( ($(date +%s) - $(stat -c %Y "$newest")) / 3600 ))
  [ "$age_h" -le 48 ] || echo "WARNING: newest backup is ${age_h}h old - is the Pi's nightly backup running?"
fi
[ -s "$LOCAL_DIR/FAILED.log" ] && { echo "WARNING: the Pi reported failed backups:"; tail -3 "$LOCAL_DIR/FAILED.log"; }

find "$LOCAL_DIR" -mindepth 1 -maxdepth 1 -type d -name '20*Z' -mtime +"$RETENTION_DAYS" -print -exec rm -rf {} +
echo "=== $(date -Is) pull done"
