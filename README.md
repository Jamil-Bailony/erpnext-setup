# ERP

ERPNext v16 + [arabic_translations](https://github.com/ibrahim317/erpnext-arabic-full-translation)
(full Arabic UI, overlay mode) + `erp_custom` (our app for all customisations: UI, fonts,
and later fields, reports, scripts). Runs on a Raspberry Pi 4 for 3–5 users over Netbird; the same
image and scripts move to a server later.

The image is built by GitHub Actions (arm64 + amd64), never on the Pi.
Runbooks: [docs/deployment.md](docs/deployment.md) (build, deploy, restore, server) and
[docs/pi-setup.md](docs/pi-setup.md) (moving the Pi over, backups).

## Development

Needs Docker with Compose. Everything goes through `./dev` (or VS Code "Reopen in Container").

```bash
./dev init                     # first time: bench + sites erp.localhost and test.localhost (~10 min)
./dev start                    # dev server -> http://erp.localhost:8001 (Administrator / admin); -d for background
./dev bench migrate            # after DocType JSON changes or git pull
./dev bench clear-cache        # after editing hooks.py
./dev bench build --app erp_custom   # after CSS/JS changes, if `start` is not running (it watches)
./dev test --app erp_custom    # tests, on test.localhost
./dev console | mariadb | shell
./dev meta Employee            # compact field list of a DocType
./dev backup | restore | reset | destroy
./dev help                     # everything else
```

- The bench lives in `development/frappe-bench/` (git-ignored, ~2 GB). Frappe and ERPNext are
  cloned there at the pinned tags. `apps/erp_custom` is linked in, so you edit it right here
  in the repo, and DocTypes you save in developer mode are written into it.
- Ports 8001 / 9001 / 8026 (mail), so it can run next to another Frappe dev stack on 8000.
  `*.localhost` resolves to 127.0.0.1 in most browsers; otherwise add it to `/etc/hosts`.
- Dev credentials (DB root `123`, Administrator `admin`) are local only.
- Monthly upstream check: `scripts/check-updates.sh [--apply]`.

## Layout

| Path | What |
|---|---|
| `versions.env`, `apps.json` | Release pins: Frappe tag, base images, ERPNext tag, translations branch |
| `apps/erp_custom/` | Our Frappe app |
| `images/Containerfile` | Release image (Frappe + ERPNext + erp_custom) |
| `images/nginx/` | nginx template with the stale-IP (502) fix |
| `images/check-assets.py` | Fails the build if built CSS/JS don't match the manifest |
| `dev`, `docker/` | Development stack and bench setup (`./dev help`) |
| `.devcontainer/`, `.vscode/` | VS Code "Reopen in Container" + debugger configs |
| `scripts/build-image.sh` | Local build, for testing on a PC |
| `scripts/check-updates.sh` | Report/apply newer Frappe/ERPNext/frappe_docker pins |
| `scripts/frappe-meta.py`, `frappe-run.py` | Helpers behind `./dev meta` and `./dev run` |
| `.github/workflows/build.yml` | CI: build, push to GHCR, verify (install + upgrade) |
| `deploy/frappe_docker/` | Upstream compose files (git submodule, pinned) |
| `deploy/dc`, `deploy/deploy.sh` | Compose wrapper and init/deploy/backup/status |
| `deploy/nightly-backup.sh` | Cron job on the Pi: backup, verify, prune |
| `scripts/pull-backups.sh` | Cron job on the PC: pull the Pi's backups, check them |
| `deploy/compose.base.yaml` | Our overrides for every host (log rotation) |
| `deploy/compose.pi.yaml` | Pi memory tuning |
| `deploy/env/example.env` | Template for `deploy/env/<host>.env` (git-ignored) |
| `docs/archive/` | Earlier hand-built Pi runbooks and the backup system |

## Common tasks

```bash
# release: change something, push to main, wait for the Build run, then on the Pi:
deploy/deploy.sh deploy pi <image-ref from the run summary>

# upgrade ERPNext: bump FRAPPE_REF in versions.env and the tag in apps.json, push, deploy
deploy/deploy.sh status pi
```

Clone with submodules: `git clone --recurse-submodules <url>`.
