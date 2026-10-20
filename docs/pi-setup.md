# Pi: move to the new setup, and backups

One-time move of the running Pi (old hand-built image + `~/erpnext-docker/dc.sh`) to this
repo's tooling (CI image + `deploy/deploy.sh`), then the backup system that goes with it.
Keeps all data: the same database and sites volumes are reused.

Plan about an hour, outside working hours (users will see a maintenance page for ~10–20 min
during step 5). Have this PC on, with this repo.

Image to deploy: take the ref from the latest green **Build** run summary on GitHub
(Actions → Build → summary), e.g.
`ghcr.io/jamil-bailony/erp:63ed94e@sha256:3fd6830c…`. Below it is `$REF`.

## 1. Final backup on the old setup

```bash
ssh root@raspberrypi.local
su - pi                     # everything below runs as pi (owner of the stack, in the docker group)

docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}'   # erpnext-* containers up
~/erpnext-docker/backup.sh                                         # the existing nightly script
ls -lt /mnt/backup/erpnext-site-backups | head -5                  # today's files are there

# Encryption key: Frappe creates it the first time something encrypted is saved
# (a password field). 0 = none yet, so nothing encrypted can be lost. Once it exists,
# every backup carries it inside *-site_config_backup.json.
docker exec erpnext-backend-1 grep -c encryption_key sites/erp.local/site_config.json
```

On the PC, pull that backup with the old script, so it is off the Pi before anything changes:

```bash
~/my-scripts/erpnext-backup-pull.sh
ls -lt ~/erpnext-backups-from-pi | head -5
```

Optional, recommended if the data changed a lot since 19 Oct: rehearse step 4 on the PC with
this backup (appendix A).

## 2. Install the new tooling on the Pi (site keeps running)

```bash
git --version && docker compose version           # both needed
git clone --recurse-submodules https://github.com/Jamil-Bailony/erpnext-setup.git ~/erp
cd ~/erp

cp deploy/env/example.env deploy/env/pi.env
# the database volume only accepts its original root password: take it from the old .env
DBP="$(sed -n 's/^DB_PASSWORD=//p' ~/erpnext-docker/.env)"
sed -i "s|^DB_PASSWORD=.*|DB_PASSWORD=$DBP|" deploy/env/pi.env
chmod 600 deploy/env/pi.env
grep -v '^#' deploy/env/pi.env | grep .
```

Expected: `COMPOSE_PROJECT=erpnext`, `SITE_NAME=erp.local`, `FRAPPE_SITE_NAME_HEADER=erp.local`,
`DB_PASSWORD=<the old one>`, `COMPOSE_OVERRIDES=compose.pi.yaml`, `PROXY=noproxy`,
`HTTP_PUBLISH_PORT=8080`, `BACKUP_DIR=/mnt/backup/erp-backups`, `BACKUP_RETENTION_DAYS=14`.

```bash
mkdir -p /mnt/backup/erp-backups
REF='ghcr.io/jamil-bailony/erp:<sha>@sha256:<digest>'    # from the Build run summary
docker pull "$REF"         # ~1.5 GB download, a few minutes; the site is still up meanwhile
```

## 3. Take over the stack, and a backup in the new format

```bash
cd ~/erp
deploy/deploy.sh adopt pi          # records the running image as the current release
deploy/deploy.sh backup pi         # -> /mnt/backup/erp-backups/<UTC stamp>/
ls -l /mnt/backup/erp-backups/*/
```

Each backup folder: `*-database.sql.gz`, `*-files.tar`, `*-private-files.tar`,
`*-site_config_backup.json`, `site_config.json`, `image.env` (the image it belongs to).

## 4. Remove saas_theme (rehearsed on the PC: clean, no leftovers)

```bash
deploy/dc pi exec backend bench --site erp.local uninstall-app saas_theme --yes
deploy/dc pi exec backend bench --site erp.local list-apps
# expect: frappe, erpnext, arabic_translations
```

If the uninstall fails: stop. The site still runs on the old image, nothing else changed.

## 5. Deploy the new image

```bash
deploy/deploy.sh deploy pi "$REF"
```

It closes the site (maintenance page), backs up, migrates, installs `erp_custom`, starts all
services on the new image, checks them, and reopens the site. It ends with
`==> deployed …`. Then:

```bash
deploy/deploy.sh status pi         # containers, app versions (versions.json), ping 200
```

Open http://raspberrypi.local:8080 (or the Netbird IP), log in as an Arabic user: Noto fonts,
Arabic labels, your data.

If it fails, the script says so, keeps the site closed and names the backup taken in this
run. Don't improvise: copy the output and restore that backup on the previous image
(docs/deployment.md section 6). The old image is still on the Pi.

## 6. Switch the nightly backup

```bash
crontab -e
```

Replace the old line (`… /home/pi/erpnext-docker/backup.sh …`) with:

```
0 2 * * * /home/pi/erp/deploy/nightly-backup.sh pi
```

Run it once by hand and check:

```bash
~/erp/deploy/nightly-backup.sh pi; echo "exit $?"
tail -8 ~/erp/deploy/logs/nightly-backup.log      # "verified …" and "done"
ls /mnt/backup/erp-backups/
```

What it does: `deploy.sh backup` (database, files, both site configs, image name) →
`gzip -t`/`tar -t` checks → deletes folders older than `BACKUP_RETENTION_DAYS`. A failure is
appended to `/mnt/backup/erp-backups/FAILED.log`, which the PC pull reports.

Old leftovers, after a week of good nightly runs: `rm -rf ~/erpnext-docker ~/frappe_docker`,
`rm -rf /mnt/backup/erpnext-site-backups` (the PC keeps its copies), and old images:
`docker images`, `docker rmi custom:<tag> …`, `docker builder prune -a`.
Don't run `~/erpnext-docker/dc.sh up` again before deleting it: it would put the old image back.

## 7. Backups to this PC

Same idea as before (the PC pulls whenever it is on; LAN first, Netbird as fallback), from the
new folder, with checks. On the PC, from this repo:

```bash
install -m 755 scripts/pull-backups.sh ~/my-scripts/erp-pull-backups.sh
# Netbird fallback (the old script still had the "<pi-netbird-ip>" placeholder, so it never
# worked away from home): the Pi's IP is in `netbird status -d` on the PC.
mkdir -p ~/.config && echo 'PI_NETBIRD_HOST=100.x.y.z' > ~/.config/erp-pull-backups.env
~/my-scripts/erp-pull-backups.sh
tail -5 ~/erp-backups-from-pi/logs/pull.log         # "newest backup OK: <stamp>"
```

`crontab -e` on the PC: replace the two old `erpnext-backup-pull.sh` lines with

```
0 23 * * 1-5 /home/galileo/my-scripts/erp-pull-backups.sh
@reboot sleep 120 && /home/galileo/my-scripts/erp-pull-backups.sh
```

The PC keeps 60 days (`RETENTION_DAYS`). It warns in the log when the newest backup is older
than 48 h or when the Pi reported a failed backup. Keep the old `~/erpnext-backups-from-pi`
until the new one has a few weeks of history.

## 8. Monthly: prove a backup restores (on the PC)

```bash
cd /media/galileo/data/work/erpnext-setup
S=$(ls ~/erp-backups-from-pi | grep 'Z$' | tail -1)
cp -r ~/erp-backups-from-pi/$S development/backups/pi-$S
./dev restore development/backups/pi-$S      # Administrator / admin, email accounts off
./dev start                                  # http://erp.localhost:8001
```

That restores into the dev site with the same apps as the Pi. Delete old copies in
`development/backups/` now and then; they are git-ignored.

## Releases after this

Push to `main` → wait for the green Build run → on the Pi:

```bash
cd ~/erp && git pull && git submodule update --init
deploy/deploy.sh deploy pi '<ref from the run summary>'
```

## Appendix A: rehearse the saas_theme removal on the PC

Done on 2026-10-20 with the 19 Oct backup. To repeat with a newer one (old flat backup format,
from `~/erpnext-backups-from-pi`):

```bash
mkdir -p development/backups/pi-<date>
cp ~/erpnext-backups-from-pi/<stamp>-erp_local-* development/backups/pi-<date>/
./dev bench get-app https://github.com/vineyrawat/saas_theme --branch version-16   # the backup has it installed
./dev restore development/backups/pi-<date>
./dev bench --site erp.localhost uninstall-app saas_theme --yes
./dev bench remove-app saas_theme --no-backup --force
./dev bench --site erp.localhost migrate          # must finish without errors
```
