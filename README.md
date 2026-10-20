# ERP

ERPNext v16 + `erp_custom` (our app for all customisations: UI, fonts, and later
fields, reports, scripts). Runs on a Raspberry Pi 4 for 3–5 users over Netbird; the same
image and scripts move to a server later.

The image is built by GitHub Actions (arm64 + amd64), never on the Pi.
Runbook: [docs/deployment.md](docs/deployment.md).

## Layout

| Path | What |
|---|---|
| `versions.env`, `apps.json` | Release pins: Frappe tag, base images, ERPNext tag |
| `apps/erp_custom/` | Our Frappe app |
| `images/Containerfile` | Release image (Frappe + ERPNext + erp_custom) |
| `images/nginx/` | nginx template with the stale-IP (502) fix |
| `images/check-assets.py` | Fails the build if built CSS/JS don't match the manifest |
| `scripts/build-image.sh` | Local build, for testing on a PC |
| `.github/workflows/build.yml` | CI: build, push to GHCR, verify (install + upgrade) |
| `deploy/frappe_docker/` | Upstream compose files (git submodule, pinned) |
| `deploy/dc`, `deploy/deploy.sh` | Compose wrapper and init/deploy/backup/status |
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
