# ERPNext Backup System

Two independent layers: the Pi backs itself up every night regardless of anything else; your PC pulls a copy whenever it happens to be on. If one layer misses a night, the other still has you covered.

## Secrets — what needs saving separately, what doesn't

- **Encryption key — the one that actually matters.** Frappe generates this lazily, the first time something needs encrypting (a saved Password-type field, a stored API key/secret on some doctype). It lives in `site_config.json`, **not** in `bench backup`'s own output — so a normal backup can silently miss it. If it ever exists and you restore without it, any encrypted data becomes permanently unreadable, not just hard to access. As of last check, no key existed yet (nothing encrypted stored so far) — but rather than remembering to keep checking, the nightly script below now saves `site_config.json` automatically every night, so this is handled going forward without needing to think about it.
- **DB root password** — not something you need to pre-save. It's always retrievable live from the running container (`docker exec erpnext-db-1 printenv MYSQL_ROOT_PASSWORD`), and a full disaster-recovery rebuild creates a fresh one anyway.
- **Administrator password** — not needed either; `bench restore` brings back the original password hash automatically, and it's always resettable (`bench set-admin-password`) if needed.
- **SSH key** (`~/.ssh/erpnext_backup_key` on your PC) — worth keeping a copy somewhere safe (password manager, encrypted drive). Not catastrophic if lost — just regenerate and re-authorize on the Pi — but saves the (minor) hassle.
- **Netbird access** — tied to your Netbird account login (browser SSO), not a static credential to store. Just remember which account to log back into if the Pi ever needs full re-registration.

## Part 1 — Pi side: nightly local backup

Runs every night regardless of network/PC state. Includes an integrity check and now also saves `site_config.json` (see Secrets above).

```bash
cat > ~/erpnext-docker/backup.sh <<'EOF'
#!/bin/bash
set -e
SITE=erp.local
CONTAINER=erpnext-backend-1
LOCAL_BACKUP_DIR=/mnt/backup/erpnext-site-backups
RETENTION_DAYS=14

mkdir -p "$LOCAL_BACKUP_DIR"
cd ~/erpnext-docker
./dc.sh exec backend bench --site "$SITE" backup --with-files
docker cp "$CONTAINER":/home/frappe/frappe-bench/sites/"$SITE"/private/backups/. "$LOCAL_BACKUP_DIR"/

# Also grab site_config.json — holds the encryption_key if one exists, which
# bench's own backup does NOT include, but which is required to decrypt any
# encrypted fields (saved passwords, API keys) after a restore.
docker exec "$CONTAINER" cat sites/"$SITE"/site_config.json > "$LOCAL_BACKUP_DIR"/site_config_$(date +%Y%m%d_%H%M%S).json

# Integrity check — catches truncated/corrupt files immediately, cheaply
LATEST_SQL=$(ls -t "$LOCAL_BACKUP_DIR"/*database.sql.gz | head -1)
if ! gzip -t "$LATEST_SQL"; then
    echo "CORRUPT BACKUP DETECTED: $LATEST_SQL — $(date)" | tee -a "$LOCAL_BACKUP_DIR"/../backup-errors.log
    exit 1
fi
for f in "$LOCAL_BACKUP_DIR"/*files.tar; do
    [ -e "$f" ] || continue
    if ! tar -tf "$f" > /dev/null; then
        echo "CORRUPT BACKUP DETECTED: $f — $(date)" | tee -a "$LOCAL_BACKUP_DIR"/../backup-errors.log
        exit 1
    fi
done

find "$LOCAL_BACKUP_DIR" -type f -mtime +$RETENTION_DAYS -delete
docker exec "$CONTAINER" bash -c "find /home/frappe/frappe-bench/sites/$SITE/private/backups -type f -mtime +$RETENTION_DAYS -delete"
echo "Backup completed and verified: $(date)"
EOF
chmod +x ~/erpnext-docker/backup.sh
```

Test manually before trusting it to a schedule:
```bash
~/erpnext-docker/backup.sh
ls -lh /mnt/backup/erpnext-site-backups/
```

Schedule nightly at 2 AM:
```bash
crontab -e
```
Add:
```
0 2 * * * /home/pi/erpnext-docker/backup.sh >> /home/pi/erpnext-docker/backup.log 2>&1
```

## Part 2 — PC side: pull whenever the PC is on

Your PC is usually off/asleep overnight, with a semi-reliable window weeknights around 23:00–00:00 — so the PC *pulls* from the Pi (always-on) rather than the Pi trying to push to an unpredictable target.

### One-time setup

SSH key (the Pi already runs normal `sshd` — no new server needed):
```bash
# on your PC
ssh-keygen -t ed25519 -f ~/.ssh/erpnext_backup_key -N ""
ssh-copy-id -i ~/.ssh/erpnext_backup_key.pub pi@<pi-netbird-ip>
ssh -i ~/.ssh/erpnext_backup_key pi@<pi-netbird-ip> "echo connected"   # confirm passwordless
```

Passwordless Netbird toggling (cron can't answer a `sudo` password prompt):
```bash
which netbird   # note the path
echo "$USER ALL=(root) NOPASSWD: /usr/bin/netbird up, /usr/bin/netbird down" | sudo tee /etc/sudoers.d/netbird-backup
```

> **Gotcha hit and fixed during setup:** if the Pi's NetBird has `--allow-server-ssh` enabled, NetBird intercepts port 22 *over its own tunnel interface* and reroutes it to its own browser/SSO-based SSH server — completely bypassing your key and the Pi's normal `sshd`. This only shows up when connecting via the Netbird IP specifically (a LAN connection like `raspberrypi.local` never touches it). Fixed on the Pi with:
> ```bash
> sudo netbird down
> sudo netbird up --allow-server-ssh=false
> ```
> (If it doesn't take effect live, `sudo reboot` the Pi and retest — this toggle is documented as flaky on Linux.)

### The pull script

```bash
cat > ~/erpnext-backup-pull.sh <<'EOF'
#!/bin/bash
set -e
PI_IP="<pi-netbird-ip>"
PI_USER="pi"
SSH_KEY="$HOME/.ssh/erpnext_backup_key"
REMOTE_DIR="/mnt/backup/erpnext-site-backups/"
LOCAL_DIR="$HOME/erpnext-backups-from-pi"
RETENTION_DAYS=60

mkdir -p "$LOCAL_DIR"

WE_CONNECTED=false
if ! netbird status --check ready; then
    echo "Connecting to Netbird..."
    sudo netbird up
    WE_CONNECTED=true
    sleep 5
fi

if ! ssh -i "$SSH_KEY" -o ConnectTimeout=10 "${PI_USER}@${PI_IP}" "echo ok" > /dev/null 2>&1; then
    echo "Cannot reach Pi, aborting."
    [ "$WE_CONNECTED" = true ] && sudo netbird down
    exit 1
fi

rsync -avz -e "ssh -i $SSH_KEY" "${PI_USER}@${PI_IP}:${REMOTE_DIR}" "$LOCAL_DIR/"

find "$LOCAL_DIR" -type f -mtime +$RETENTION_DAYS -delete

if [ "$WE_CONNECTED" = true ]; then
    echo "Disconnecting Netbird..."
    sudo netbird down
fi
echo "Pull completed: $(date)"
EOF
chmod +x ~/erpnext-backup-pull.sh
```
No `rsync --delete` — the PC accumulates a longer history than the Pi's own 14-day-pruned copy (pruned separately here at 60 days), acting as the real long-term archive.

Test manually:
```bash
~/erpnext-backup-pull.sh
ls -lh ~/erpnext-backups-from-pi/
```

Schedule — targeted attempt plus a catch-up on boot, since plain cron won't retry a missed slot:
```bash
crontab -e
```
Add both:
```
0 23 * * 1-5 /home/YOU/erpnext-backup-pull.sh >> /home/YOU/erpnext-backup-pull.log 2>&1
@reboot sleep 120 && /home/YOU/erpnext-backup-pull.sh >> /home/YOU/erpnext-backup-pull.log 2>&1
```

## Part 3 — Testing a backup is actually restorable

A backup that "completes without error" isn't proof it's restorable. Two checks, two different costs:

1. **Nightly integrity check** (already built into `backup.sh` above) — `gzip -t` and `tar -tf` catch a truncated/corrupt file immediately. Cheap, but only proves the file isn't broken, not that a full restore actually works end to end.
2. **Real test-restore** — the only thing that actually proves it. Uses the existing isolated `~/erpnext-test` stack, so zero risk to production.

### Test-restore procedure (confirmed working)

```bash
cd ~/erpnext-test
./dc-test.sh down -v
./dc-test.sh up -d
DB_PASSWORD=$(docker exec erpnext-test-db-1 printenv MYSQL_ROOT_PASSWORD)
./dc-test.sh exec backend bench new-site erp-test.local --mariadb-user-host-login-scope=% --db-root-password "$DB_PASSWORD" --admin-password "test1234" --install-app erpnext --set-default
```

Copy the most recent real backup in:
```bash
LATEST=$(ls -t /mnt/backup/erpnext-site-backups/*database.sql.gz | head -1 | sed 's/-database.sql.gz//')
docker cp "${LATEST}-database.sql.gz" erpnext-test-backend-1:/home/frappe/frappe-bench/sites/erp-test.local/private/backups/
docker cp "${LATEST}-private-files.tar" erpnext-test-backend-1:/home/frappe/frappe-bench/sites/erp-test.local/private/backups/
docker cp "${LATEST}-files.tar" erpnext-test-backend-1:/home/frappe/frappe-bench/sites/erp-test.local/private/backups/
```

Restore — **use full absolute paths, not bare filenames** (bare filenames intermittently produced `Invalid path` errors; absolute paths resolved it cleanly every time):
```bash
./dc-test.sh exec -e DB_ROOT_PASSWORD="$DB_PASSWORD" backend bash -c '
cd sites/erp-test.local/private/backups
DB_FILE="$(pwd)/$(ls *database.sql.gz)"
PRIVATE_FILES="$(pwd)/$(ls *private-files.tar 2>/dev/null)"
PUBLIC_FILES="$(pwd)/$(ls *files.tar 2>/dev/null | grep -v private)"
echo "DB: $DB_FILE"
echo "Private: $PRIVATE_FILES"
echo "Public: $PUBLIC_FILES"
bench --site erp-test.local restore "$DB_FILE" --db-root-password "$DB_ROOT_PASSWORD" --with-private-files "$PRIVATE_FILES" --with-public-files "$PUBLIC_FILES" --force
'
```

Open `http://raspberrypi.local:8081`, log in, confirm it's genuinely your real data.

> **Note on `bench migrate` after this test-restore:** it will fail with a `ModuleNotFoundError` for any app the backup's metadata says is installed (`arabic_translations`, `saas_theme`) that isn't in the test stack's current image. This is expected and not a backup problem — same root cause as the earlier HRMS removal saga (app metadata travels with the backup; the image it's restored onto has to match). The database restore itself — the part that actually matters — already succeeded by that point. To fully close this loop, rebuild the test image with the real production app set (another ~20–30 min build) and rerun — deferred for now, not required to consider the backup system validated.

**Why we don't test-restore onto production itself:** the backup being tested *is* production's own latest backup — restoring it onto production would just restore production onto itself, proving nothing new while carrying real risk (interruption mid-restore) to the live system. The isolated test stack proves the same thing — backup → transfer → restore genuinely works — with zero risk.

**Recommended cadence:** repeat this test-restore roughly monthly. Costs nothing (test stack already exists), and it's the only real guarantee the whole chain still works as things change over time.
