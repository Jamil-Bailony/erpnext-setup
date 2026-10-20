# Agent instructions

ERPNext v16 for a small private deployment (Raspberry Pi 4 now, a server later).
Read README.md (dev workflow, layout) and docs/deployment.md (build and deploy) first.

## Rules

- Every customisation goes into `apps/erp_custom` (hooks, CSS/JS bundles, fixtures, patches,
  DocTypes). No `sed` patches on upstream apps in the image build, no third-party themes.
- Never run `bench build` in a deployed container. Assets are built into the image; the
  Containerfile checks the manifest (`images/check-assets.py`).
- Release pins live in `versions.env` and `apps.json` only. Bump both together
  (`scripts/check-updates.sh --apply`).
- Keep `deploy/frappe_docker` (submodule) unmodified. Our compose changes go in
  `deploy/compose.base.yaml` (all hosts) or `deploy/compose.<host>.yaml`.
- Deploy only with `deploy/deploy.sh`; it backs up, migrates and checks. `deploy/env/*.env`
  and `deploy/state/` hold secrets/state and are git-ignored.
- Dev: run commands through `./dev` (`./dev bench ...`, `./dev test --app erp_custom`).
  Use `./dev meta <DocType>` to look up fields instead of reading DocType JSON.
- The users read Arabic. UI work must look right in RTL (Frappe builds a css-rtl variant of
  every bundle automatically).
