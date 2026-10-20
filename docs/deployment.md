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

What a push costs:

| Changed | CI does | Pi downloads |
|---|---|---|
| docs, `dev`, `development/`, `docker/`, `scripts/` | nothing (no run) | nothing |
| `deploy/` scripts only | reuses the image (tag `inputs-<hash>`), runs verify | nothing new |
| `apps/erp_custom` | rebuilds only the custom-app layer (~2 min) | ~40 MB |
| `apps.json`, `versions.env` (new Frappe/ERPNext) | full build (~8 min) | ~1.6 GB |

The Frappe + ERPNext bench is its own image layer, cached in GHCR
(`buildcache-arm64`/`-amd64` tags). Actions → Build → Run workflow → "force_build" rebuilds
even when nothing changed.

## 2. Host setup (once per host)

```bash
git clone --recurse-submodules <repo-url> ~/erp
cd ~/erp
cp deploy/env/example.env deploy/env/pi.env     # then edit it
# only if the package is private: a classic token with read:packages
# echo <token> | docker login ghcr.io -u <github-user> --password-stdin
```

## 3. Moving the existing Pi stack over (once)

Step by step, with the backup setup (Pi nightly + PC pull + monthly restore test):
[pi-setup.md](pi-setup.md).

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
   B=/mnt/backup/erp-backups/<stamp>
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
