# Deployment runbook

How the ERP is built and deployed. The image is built by GitHub Actions, never on the Pi.
The Pi (and later a server) only pulls the image and runs `deploy/deploy.sh`.

```
push to main ──► GitHub Actions: build arm64 + amd64 ──► ghcr.io/<owner>/erp:<sha>
                                 verify on arm64 (install + upgrade)        │
                                                                            ▼
                                     Pi: deploy/deploy.sh deploy pi <image-ref>
                                         (backup ► migrate ► checks ► reopen)
```

## 1. GitHub setup (once)

1. Create a GitHub repo (private is fine) and push this repo to it.
2. Settings → Actions → General → Workflow permissions: **Read and write**. That lets the
   workflow push to GHCR with the built-in token, so no secrets are needed.
3. The first run creates the package `ghcr.io/<owner>/erp`. It is private when the repo is private.
   Either make the package public (it holds no secrets) or give the Pi a token, see 2.

The `build` job uses the `ubuntu-24.04-arm` runner. If your plan does not offer arm runners for
private repos, the job waits in the queue. Then make the repo public, or change the
arm64 runner to `ubuntu-latest` and add `docker/setup-qemu-action@v3` before buildx. That
works but is slow, since it emulates arm64.

Actions → Build → the run summary prints the image ref to deploy, e.g.
`ghcr.io/owner/erp:1a2b3c4@sha256:…`. Always deploy the `@sha256` form.

## 2. Host setup (once per host)

```bash
git clone --recurse-submodules <repo-url> ~/erp
cd ~/erp
cp deploy/env/example.env deploy/env/pi.env     # then edit it
# only if the package is private: a classic token with read:packages
# echo <token> | docker login ghcr.io -u <github-user> --password-stdin
```

## 3. Moving the existing Pi stack over (once)

The current stack runs under compose project `erpnext` with site `erp.local`, from
`~/erpnext-docker/dc.sh`. Keep that project name in `pi.env` (`COMPOSE_PROJECT=erpnext`),
so the same database and sites volumes are reused and nothing is recreated from scratch.

### 3a. First: make the nightly backup keep the encryption key

`~/erpnext-docker/backup.sh` saves the database and files but not `site_config.json`, and
Frappe's own `*-site_config_backup.json` has no `encryption_key`. Without the key a restore
keeps all data but loses every saved password (email accounts, API keys). On the Pi, add after
the `bench ... backup --with-files` line of `backup.sh`:

```bash
STAMP=$(ls -t "$LOCAL_BACKUP_DIR"/*-database.sql.gz | head -1 | xargs basename | sed 's/-database.sql.gz//')
docker exec erpnext-backend-1 cat sites/erp.local/site_config.json > "$LOCAL_BACKUP_DIR/$STAMP-site_config.json"
chmod 600 "$LOCAL_BACKUP_DIR/$STAMP-site_config.json"
```

Check the line that copies the backup into `$LOCAL_BACKUP_DIR` runs before this (adjust if
your script copies afterwards). Run `backup.sh` once by hand and confirm
`grep -c encryption_key /mnt/backup/erpnext-site-backups/*-site_config.json` finds it.
`./dev restore` and a manual restore both pick that file up.

### 3b. Rehearse on the PC (dev environment)

Done once on 2026-10-20 with the 19 Oct backup: clean uninstall, no leftovers, data and
desk fine. Repeat it with a fresh backup right before the real move:

```bash
# 1. one backup per folder, inside the repo (the dev container only sees the repo)
mkdir -p development/backups/pi-<date>
cp ~/erpnext-backups-from-pi/<stamp>-erp_local-* development/backups/pi-<date>/
#    plus <stamp>-site_config.json once 3a is in place

# 2. the backup's site has saas_theme installed: give the dev bench its code for now
./dev bench get-app https://github.com/vineyrawat/saas_theme --branch version-16

# 3. restore into erp.localhost (asks first; backs up the dev site; switches the backup's
#    email accounts off; Administrator / admin; installs erp_custom)
./dev restore development/backups/pi-<date>

# 4. the step to rehearse
./dev bench --site erp.localhost uninstall-app saas_theme --yes
./dev bench --site erp.localhost list-apps   # frappe, erpnext, arabic_translations, erp_custom

# 5. drop its code like the new image does, then migrate again: must finish without errors
./dev bench remove-app saas_theme --no-backup --force
./dev bench --site erp.localhost migrate

# 6. look: ./dev start, http://erp.localhost:8001 - log in as an Arabic user too
#    (./dev bench --site erp.localhost set-password <email> <pw>), open invoices, reports,
#    check fonts and translations
```

To start over: run `./dev restore` again (step 2 is needed again only after step 5).

### 3c. On the Pi

1. Host setup from section 2: clone to `~/erp`. The GHCR package is public, so no
   `docker login` is needed.
2. In `deploy/env/pi.env` set `DB_PASSWORD` to the value from `~/erpnext-docker/.env`
   (the database volume only accepts its original password), `COMPOSE_PROJECT=erpnext`,
   `SITE_NAME=erp.local`, `FRAPPE_SITE_NAME_HEADER=erp.local`,
   `COMPOSE_OVERRIDES=compose.pi.yaml`, `BACKUP_DIR=/mnt/backup/erp-deploy-backups`.
3. With the old stack running:
   ```bash
   deploy/deploy.sh adopt pi        # records the running image as the current release
   deploy/deploy.sh backup pi       # backup including site_config.json (encryption key)
   ```
   Copy that backup folder to the PC as well.
4. Remove saas_theme (as rehearsed). Uninstalling deletes only the app's own data; it has no
   business data. Keep `arabic_translations`: the image has its newer version.
   ```bash
   deploy/dc pi exec backend bench --site erp.local uninstall-app saas_theme --yes
   deploy/dc pi exec backend bench --site erp.local list-apps    # frappe, erpnext, arabic_translations
   ```
   If this fails, stop here: the site still runs on the old image, nothing else changed.
5. Deploy the image from CI (the run summary prints the ref):
   ```bash
   deploy/deploy.sh deploy pi ghcr.io/jamil-bailony/erp:<sha>@sha256:<digest>
   ```
   It refuses to start if the site still has an app the image lacks. Otherwise: backup,
   migrate, install `erp_custom`, start, checks, reopen.
6. Retire the old tooling. Do **not** run `~/erpnext-docker/dc.sh up` again: it would
   recreate the containers on the old image. In `~/erpnext-docker/backup.sh` replace
   ```bash
   cd ~/erpnext-docker
   ./dc.sh exec backend bench --site "$SITE" backup --with-files
   ```
   with
   ```bash
   ~/erp/deploy/dc pi exec -T backend bench --site "$SITE" backup --with-files
   ```
   The rest of the backup system is unchanged, because container names (`erpnext-backend-1`,
   `erpnext-db-1`) stay the same.
7. Clean up old images once all is well: `docker images | grep custom`, `docker rmi …`,
   `docker builder prune -a`. Keep `~/frappe_docker` for reference or delete it.

## 4. Deploying a new release

```bash
cd ~/erp && git pull && git submodule update --init
deploy/deploy.sh deploy pi <image-ref>
```

`deploy` refuses to start if the site has an app the image lacks. Otherwise it:
puts the site in maintenance mode → stops traffic and workers → backs up to `BACKUP_DIR`
→ migrates on the new image → installs apps new in the image (in image order) → starts everything →
waits for workers and HTTP → reopens the site.

No site reset, no `bench build` on the Pi. Assets come built and checked inside the image.

If any step fails, the site stays closed and the script prints the backup to restore. Do not
just switch back to the old image, because the database may be partly migrated. Restore that
backup on the previous image (section 6), then delete `deploy/state/pi.pending`. Until then
`deploy` refuses to run.

## 5. Day-to-day

```bash
deploy/deploy.sh status pi                 # release, containers, app commits, ping
deploy/deploy.sh backup pi                 # ad-hoc backup
deploy/dc pi logs -f backend               # any docker compose command
deploy/dc pi exec backend bench --site erp.local console
deploy/dc pi exec backend bench --site erp.local set-admin-password '<new>'
```

## 6. Restore

Each backup is `BACKUP_DIR/<UTC timestamp>/`: database, public and private files,
`site_config.json` (holds the **encryption key**) and `image.env` (the image it belongs to).

1. Make sure the stack runs the image named in `image.env` (the `IMAGE_REF` in
   `deploy/state/pi.env`; set it back there if needed, then `deploy/dc pi up -d`).
2. Copy the files in and restore (`ls "$B"` shows the `<name>` prefix of the files):
   ```bash
   B=/mnt/backup/erp-deploy-backups/<stamp>
   S=/home/frappe/frappe-bench/sites/erp.local/private/backups/restore
   deploy/dc pi exec backend mkdir -p $S
   deploy/dc pi cp "$B/." backend:$S/
   DB_PASSWORD=$(sed -n 's/^DB_PASSWORD=//p' deploy/env/pi.env)
   deploy/dc pi exec backend bench --site erp.local restore $S/<name>-database.sql.gz \
     --with-public-files $S/<name>-files.tar \
     --with-private-files $S/<name>-private-files.tar \
     --db-root-password "$DB_PASSWORD"
   deploy/dc pi exec backend bench --site erp.local migrate
   ```
3. Put `encryption_key` from the saved `site_config.json` back into the site's
   `site_config.json` if it differs, then `deploy/dc pi restart`.

## 7. Moving to a server later

Same repo, same image (CI already builds amd64). On the server:

```bash
cp deploy/env/example.env deploy/env/server.env
# COMPOSE_PROJECT=erp, COMPOSE_OVERRIDES= (empty: no Pi tuning)
# PROXY=https + SITES_RULE + LETSENCRYPT_EMAIL for a public domain, or noproxy behind a VPN
deploy/deploy.sh init server <image-ref>
```

Then move the data: `deploy/deploy.sh backup pi` on the Pi, copy the folder over, restore it
on the server (section 6). Anything specific to that server goes in a new
`deploy/compose.server.yaml`, listed in `COMPOSE_OVERRIDES`.

## 8. Testing an image on your PC before pushing

```bash
scripts/build-image.sh                         # amd64, tag erp:<sha>[-dirty]
cp deploy/env/example.env deploy/env/local.env # COMPOSE_PROJECT=erp-local, SITE_NAME=erp.localhost,
                                               # COMPOSE_OVERRIDES=, BACKUP_DIR=/tmp/erp-backups
deploy/deploy.sh init local erp:<tag>          # http://localhost:8080
deploy/dc local down -v && rm deploy/state/local.env   # throw it away
```
