# ERPNext on Raspberry Pi — Setup Runbook

## Overview
- Hardware: Raspberry Pi 4 Model B, 3.7GB usable RAM, 64-bit OS (Debian 13 "trixie"), HDD on a separate ~500GB partition, Docker root redirected there (`/mnt/backup/docker`).
- Access: private only, via Netbird mesh VPN — no public exposure, no reverse proxy/TLS.
- Stack: official [frappe_docker](https://github.com/frappe/frappe_docker) repo (base `compose.yaml` + overrides), not a hand-rolled compose file — stays in sync with upstream via `git pull`.
- Site name: `erp.local`. Apps installed: `frappe`, `erpnext`, `hrms`, `arabic_translations`.

## Folder layout
```
~/frappe_docker/     <- git clone, vendor mirror only, used only to (re)build images. git pull for updates.
~/erpnext-docker/    <- your actual deployment folder: .env, compose.my-pi-tuning.yaml, dc.sh wrapper. Always run commands from here.
```

## 1. Clone the official repo
```bash
cd ~
git clone https://github.com/frappe/frappe_docker
cd frappe_docker
```

## 2. Create the deployment folder + .env
```bash
mkdir -p ~/erpnext-docker
```
`~/erpnext-docker/.env`:
```
ERPNEXT_VERSION=v16.33.0
DB_PASSWORD=<generate with: openssl rand -base64 24>
FRAPPE_SITE_NAME_HEADER=erp.local
```
(Keep this file lean — the `example.env` template ships with unrelated Traefik/HTTPS variables like `SITES_RULE=Host(...)` that break parsing if left in. If using a custom image — see the app section below — three more lines get added here.)

## 3. Resource-tuning override (Pi-specific)
`~/erpnext-docker/compose.my-pi-tuning.yaml`:
```yaml
services:
  configurator:
    platform: linux/arm64
  backend:
    platform: linux/arm64
  frontend:
    platform: linux/arm64
  websocket:
    platform: linux/arm64
  queue-short:
    platform: linux/arm64
  queue-long:
    platform: linux/arm64
  scheduler:
    platform: linux/arm64
  db:
    healthcheck:
      start_period: 90s
    command:
      - --character-set-server=utf8mb4
      - --collation-server=utf8mb4_unicode_ci
      - --skip-character-set-client-handshake
      - --innodb-buffer-pool-size=256M
      - --innodb-buffer-pool-instances=1
      - --max-connections=50
  redis-cache:
    command: redis-server --maxmemory 100mb --maxmemory-policy allkeys-lru
  redis-queue:
    command: redis-server --maxmemory 256mb --maxmemory-policy noeviction
```
> The `platform: linux/arm64` lines are a Pi-specific safety net (official images are already multi-arch, so not strictly required, but costs nothing). Drop them on an amd64 server. Memory tuning can be raised or removed on bigger hardware.

## 4. The `dc.sh` wrapper — always reads `.env` live, never goes stale
`~/erpnext-docker/dc.sh`:
```bash
#!/bin/bash
exec docker compose -p erpnext --env-file ~/erpnext-docker/.env \
  -f ~/frappe_docker/compose.yaml \
  -f ~/frappe_docker/overrides/compose.mariadb.yaml \
  -f ~/frappe_docker/overrides/compose.redis.yaml \
  -f ~/frappe_docker/overrides/compose.noproxy.yaml \
  -f ~/erpnext-docker/compose.my-pi-tuning.yaml \
  "$@"
```
```bash
chmod +x ~/erpnext-docker/dc.sh
```
Always use `./dc.sh <docker compose subcommand>` from `~/erpnext-docker/` — never call `docker compose -f ...` directly, to avoid project-name drift.

## 5. Bring the stack up
```bash
cd ~/erpnext-docker
./dc.sh up -d
./dc.sh ps -a
```
Expect: `db`, `redis-cache`, `redis-queue`, `backend`, `frontend`, `websocket`, `queue-short`, `queue-long`, `scheduler` all `Up`; `configurator` shows `Exited (0)` — correct, it's a one-shot init container.

## 6. Create the site
```bash
DB_PASSWORD=$(docker exec erpnext-db-1 printenv MYSQL_ROOT_PASSWORD)
./dc.sh exec backend bench new-site erp.local \
  --mariadb-user-host-login-scope=% \
  --db-root-password "$DB_PASSWORD" \
  --admin-password "<pick one>" \
  --install-app erpnext \
  --set-default
```

## 7. Post-setup
```bash
./dc.sh exec backend bench --site erp.local scheduler enable
./dc.sh exec backend bench --site erp.local scheduler resume
```
Reset the admin password anytime (it can't be looked up, only reset — ERPNext stores it hashed):
```bash
NEWADMIN=$(openssl rand -base64 18)
./dc.sh exec backend bench --site erp.local set-admin-password "$NEWADMIN"
echo "$NEWADMIN"   # save immediately somewhere safe (password manager)
```

## 8. Access
- Same network as the Pi: `http://raspberrypi.local:8080`
- Remote via Netbird: `http://<pi-netbird-ip>:8080` (find with `netbird status` on the Pi)
- Login: username `Administrator`, password as set above.

---

## Adding a custom app (e.g. HRMS, a translation app)

Custom apps aren't in the official `frappe/erpnext` image — they require building your own image via `apps.json`. Batch every app you want into **one** `apps.json`/build — adding an app later means a full image rebuild **and** a fresh site, not an incremental add (see below).

### ⚠️ What went wrong here, and the rule that avoids it

Official Frappe images stage a copy of built assets **outside** `sites/` and copy it back in on every container boot (you'll see `Linking fresh assets to volume...` in `docker run`/startup logs) — this exists specifically so a persistent `sites` volume doesn't mask a new image's assets. **Any custom layer that runs `bench build` on top must redo that same staging step**, or the entrypoint will silently restore the old pre-build copy on every restart — looking like "it built fine" while actually reverting itself forever. This cost hours to track down. Two rules that prevent it:

1. **Never run `bench build` against a running production container.** Frappe's own maintainers confirm this directly: *"You cannot build assets using bench build in running production containers... Images come pre-packaged with built assets."* All building happens in the image, before any site exists.
2. **After any custom `RUN bench build` in a Dockerfile, immediately re-stage assets** with `rm -rf assets && cp -r sites/assets assets` in that same layer — and **verify with an isolated `docker run` before deploying** (command below). This isolated check is cheap and would have caught the bug immediately instead of after a full site setup.

### 1. Bump swap first (image builds are memory-hungry on a Pi)
Raspberry Pi OS trixie uses the `rpi-swap` zram+file mechanism — config in `/etc/rpi/swap.conf.d/`, needs a reboot to apply:
```bash
sudo mkdir -p /etc/rpi/swap.conf.d/
sudo tee /etc/rpi/swap.conf.d/90-local.conf > /dev/null <<'EOF'
[Zram]
FixedSizeMiB=4096
EOF
sudo reboot
```
Verify after reboot: `swapon --show` → should show `4G`.

### 2. Build the base image with all apps
```bash
cd ~/frappe_docker
cat > apps.json <<'EOF'
[
  { "url": "https://github.com/frappe/erpnext", "branch": "version-16" },
  { "url": "https://github.com/frappe/hrms", "branch": "version-16" },
  { "url": "https://github.com/ibrahim317/erpnext-arabic-full-translation", "branch": "develop" }
]
EOF

docker build \
  --no-cache \
  --build-arg=FRAPPE_PATH=https://github.com/frappe/frappe \
  --build-arg=FRAPPE_BRANCH=version-16 \
  --secret=id=apps_json,src=apps.json \
  --tag=custom:16-base \
  --platform=linux/arm64 \
  --file=images/layered/Containerfile \
  .
```
(`--no-cache` costs more build time but avoids stale-layer surprises — worth it for anything touching assets. Cancel a running build with **Ctrl+C**, not Ctrl+D.)

### 3. Layer on any post-install steps that need `bench build` — re-staging assets is mandatory
```bash
docker build --no-cache -t custom:16-built -f - . <<'EOF'
FROM custom:16-base
RUN sed -i "s/with_internal=True/with_internal_apps=True/" apps/arabic_translations/arabic_translations/commands.py \
 && bench install-arabic-translations \
 && bench build --force \
 && rm -rf /home/frappe/frappe-bench/assets \
 && cp -r /home/frappe/frappe-bench/sites/assets /home/frappe/frappe-bench/assets
EOF
```
(The `sed` fixes a real upstream bug in that specific translation app — calls a Frappe function with a renamed argument. Only needed for that app; skip if not using it.)

### 4. Verify BEFORE deploying — do not skip this
```bash
docker run --rm custom:16-built bash -c "grep website sites/assets/assets.json; ls sites/assets/frappe/dist/css/ | grep website"
```
The hash in the manifest line and the filename on disk **must match**. If they don't, the image itself is broken — fix it here, before touching any live container or site.

### 5. Point the deployment at it
```bash
cat >> ~/erpnext-docker/.env <<'EOF'
CUSTOM_IMAGE=custom
CUSTOM_TAG=16-built
PULL_POLICY=missing
EOF
```
(`ERPNEXT_VERSION` in `.env` is now ignored — `CUSTOM_IMAGE`/`CUSTOM_TAG` take priority.)

### 6. Full reset and fresh site — required, not optional, when switching to a new custom image
```bash
cd ~/erpnext-docker
./dc.sh down -v
./dc.sh up -d
./dc.sh ps -a

DB_PASSWORD=$(docker exec erpnext-db-1 printenv MYSQL_ROOT_PASSWORD)
./dc.sh exec backend bench new-site erp.local \
  --mariadb-user-host-login-scope=% \
  --db-root-password "$DB_PASSWORD" \
  --admin-password "<pick one>" \
  --install-app erpnext \
  --set-default

./dc.sh exec backend bench --site erp.local install-app hrms
./dc.sh exec backend bench --site erp.local install-app arabic_translations
./dc.sh exec backend bench --site erp.local migrate
./dc.sh exec backend bench --site erp.local scheduler enable
./dc.sh exec backend bench --site erp.local scheduler resume
```
Install order matters when using the translation app: install it **last**, so its locale-copy step sees every other app already installed.

Do **not** run `bench build` at any point in this section — everything is already baked into the image and verified in step 4.

**Adding another app to an existing, populated site later:** back up first (see Backups), rebuild the image with the full new `apps.json` (steps 2–5), then repeat step 6 (destroys and recreates the site) → restore the backup. There's no safe incremental path — this is why batching app decisions upfront, and having working backups, both matter.

**Not installed (deliberately deferred):** Frappe CRM — separate data model from ERPNext's own Lead/Customer records unless the optional integration is set up. Revisit once that tradeoff is worth it.

---

## Key lessons learned (base setup)
- **MariaDB's root password is set only once**, on first init of an empty data volume. Editing `DB_PASSWORD` in `.env` afterward does nothing to an already-initialized volume — `./dc.sh down -v` is required for a password change to take effect.
- **`docker compose ... config > file.yaml` freezes every `${VAR}` at generation time** — never re-reads `.env` again. This is why `dc.sh` runs live instead.
- **Always pin the Compose project name** (`-p erpnext`, baked into `dc.sh`) — otherwise it defaults to the current folder name, and moving the compose file elsewhere silently creates a second, empty set of volumes.
- **MariaDB 11.x images don't ship the `mysql` client binary** — use `mariadb` instead.
- Official `frappe/erpnext` images are genuinely multi-arch (`linux/amd64` + `linux/arm64`) — no build/buildx step needed on ARM for the base image.

## Porting to a bigger server later
- Remove the `platform: linux/arm64` lines (irrelevant on amd64).
- Raise or remove the memory limits in the tuning override.
- Consider layering `overrides/compose.https.yaml` (Traefik + Let's Encrypt) once you have a real domain, instead of Netbird-only access.
- Everything else (`.env`, `dc.sh`, folder layout, custom image workflow) carries over unchanged.

## Backups
_(next up — not yet implemented/tested)_
