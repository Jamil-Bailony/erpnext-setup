#!/usr/bin/env bash
# Deploy a release image to an environment (staging, production, ...) on this host.
#
#   deploy/deploy.sh init   <env> <image-ref>   first install: start stack, create site, install apps
#   deploy/deploy.sh deploy <env> <image-ref>   upgrade: close site, backup, migrate, check, reopen
#   deploy/deploy.sh adopt  <env>               take over a stack started by other tooling:
#                                               record its running image as the current release
#   deploy/deploy.sh backup <env>               backup database, files and site_config into BACKUP_DIR
#   deploy/deploy.sh status <env>
#
# <image-ref> is repo:tag or repo:tag@sha256:digest (CI prints the digest form; prefer it).
#
# deploy/state/<env>.env records the last release that passed its checks; it is written only
# then. deploy/state/<env>.pending exists while a deploy runs and stays after one fails: it names
# the backup to restore and blocks further deploys until that is done.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

cmd="${1:-}"; ENV_NAME="${2:-}"
[ -n "$cmd" ] && [ -n "$ENV_NAME" ] || { sed -n '2,15p' "$0"; exit 1; }
ENV_FILE="$HERE/env/$ENV_NAME.env"
STATE_FILE="$HERE/state/$ENV_NAME.env"
PENDING_FILE="$HERE/state/$ENV_NAME.pending"
[ -f "$ENV_FILE" ] || { echo "missing $ENV_FILE" >&2; exit 1; }
set -a; source "$ENV_FILE"; set +a
source "$ROOT/versions.env"
# Seconds a stopping service gets to finish in-flight requests and the running job.
STOP_TIMEOUT="${STOP_TIMEOUT:-120}"

# Compose on the image in USE_REF if set, else on the last successful release.
dc() { IMAGE_REF_OVERRIDE="${USE_REF:-}" "$HERE/dc" "$ENV_NAME" "$@"; }
in_backend() { dc exec -T backend "$@"; }
log() { echo "==> $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

state_get() { [ -f "$STATE_FILE" ] && sed -n "s/^$1=//p" "$STATE_FILE" || true; }

# Record a successful release. Written to a temp file and renamed, so it is never half-written.
write_state() {
  mkdir -p "$HERE/state"
  cat > "$STATE_FILE.tmp" <<EOF
IMAGE_REF=$1
PREVIOUS_IMAGE_REF=$2
LAST_DEPLOY_BACKUP=$3
DEPLOYED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF
  mv -f "$STATE_FILE.tmp" "$STATE_FILE"
}

ensure_image() { docker image inspect "$1" >/dev/null 2>&1 || docker pull "$1"; }

# The compose config must run exactly this ref for the Frappe services.
assert_image() {
  local images
  images="$(USE_REF="$1" dc config --images)"
  grep -Fxq "$1" <<<"$images" || die "compose would not run $1; it renders: $(tr '\n' ' ' <<<"$images")"
}

# Site checks run in a one-off container on USE_REF: database, apps, a simple query.
site_checks() {
  log "site checks on ${USE_REF:-current release}"
  dc run --rm --no-deps -T backend bash -ec '
    apps="$(bench --site "$1" list-apps)"
    for a in frappe erpnext "$2"; do
      grep -q "^$a\b" <<<"$apps" || { echo "app $a is not installed on $1" >&2; exit 1; }
    done
    bench --site "$1" execute frappe.client.get_count --kwargs "{\"doctype\": \"Company\"}" >/dev/null
  ' _ "$SITE_NAME" "$CUSTOM_APP"
}

# Every Frappe service runs on USE_REF and stays up, and workers have registered.
services_ready() {
  local i s cid bad
  for i in $(seq 1 30); do
    bad=""
    for s in backend frontend websocket queue-short queue-long scheduler; do
      cid="$(dc ps --status running -q "$s")"
      if [ -z "$cid" ]; then bad="$bad $s(not running)"
      elif [ "$(docker inspect -f '{{.Config.Image}}' "$cid")" != "$USE_REF" ]; then bad="$bad $s(wrong image)"
      fi
    done
    if [ -z "$bad" ] && in_backend bench --site "$SITE_NAME" doctor 2>/dev/null \
         | grep -Eq '^Workers online: [1-9]'; then
      log "services up on $USE_REF, workers online"
      return 0
    fi
    sleep 2
  done
  echo "services not ready:${bad:- no workers online}" >&2
  return 1
}

http_code() {
  in_backend curl -s -o /dev/null -w '%{http_code}' -H "Host: $SITE_NAME" \
    http://frontend:8080/api/method/ping 2>/dev/null || true
}
# Wait until the site answers ping with this HTTP code (503 = up but in maintenance mode).
wait_http() {
  local i
  for i in $(seq 1 30); do
    [ "$(http_code)" = "$1" ] && { log "site answers $1"; return 0; }
    sleep 2
  done
  echo "site never answered $1 (last: $(http_code))" >&2
  return 1
}

# Every app installed on the site must exist in the new image, or migrate fails half-way.
missing_apps() {
  local image_apps site_apps a missing=""
  image_apps="$(docker run --rm --entrypoint cat "$1" /home/frappe/frappe-bench/sites/apps.txt)"
  site_apps="$(in_backend bench --site "$SITE_NAME" list-apps | awk '{print $1}')"
  for a in $site_apps; do grep -qx "$a" <<<"$image_apps" || missing="$missing $a"; done
  [ -z "$missing" ] || die "installed on $SITE_NAME but not in $1:$missing
Back up, then: deploy/dc $ENV_NAME exec backend bench --site $SITE_NAME uninstall-app <app> --yes"
}

# After maintenance mode is switched off, each gunicorn worker keeps serving 503 "Updating"
# until its in-memory site_config cache expires (Frappe: 60s). Wait for 20 straight 200s,
# so they spread over all workers.
wait_reopened() {
  local i ok=0
  for i in $(seq 1 120); do
    if [ "$(http_code)" = 200 ]; then ok=$((ok + 1)); else ok=0; fi
    [ "$ok" -ge 20 ] && { log "site open on all workers"; return 0; }
    sleep 1
  done
  echo "site still answers 503 on some workers" >&2
  return 1
}

BACKUP_DEST=""
backup() {
  local stamp site_dir=/home/frappe/frappe-bench/sites/$SITE_NAME
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  BACKUP_DEST="$BACKUP_DIR/$stamp"
  log "backup $SITE_NAME -> $BACKUP_DEST"
  in_backend rm -rf "$site_dir/private/backups/deploy"
  in_backend bench --site "$SITE_NAME" backup --with-files --backup-path "$site_dir/private/backups/deploy"
  mkdir -p "$BACKUP_DEST"
  dc cp "backend:$site_dir/private/backups/deploy/." "$BACKUP_DEST/"
  # site_config.json holds the encryption key; a restore without it loses encrypted fields.
  dc cp "backend:$site_dir/site_config.json" "$BACKUP_DEST/site_config.json"
  echo "IMAGE_REF=$(state_get IMAGE_REF)" > "$BACKUP_DEST/image.env"
  chmod -R go-rwx "$BACKUP_DEST"
  log "backup done: $(ls "$BACKUP_DEST" | tr '\n' ' ')"
}

# A deploy step failed: keep the site closed and background work stopped, say how to recover.
deploy_failed() {
  set +e
  echo >&2
  echo "DEPLOY FAILED: $1" >&2
  if [ -n "$(dc ps --status running -q backend)" ]; then
    in_backend bench --site "$SITE_NAME" set-maintenance-mode on >/dev/null 2>&1
  fi
  dc stop -t "$STOP_TIMEOUT" queue-short queue-long scheduler >/dev/null 2>&1
  cat >&2 <<EOF
The site is closed (maintenance mode, or stopped) and workers and scheduler are stopped.
deploy/state/$ENV_NAME.env still records the last good release: $FROM_REF
The database may be partly migrated. Recover by restoring this backup on that image,
not by switching the image back alone:
  $BACKUP_DEST
Then remove $PENDING_FILE.
EOF
  exit 1
}

case "$cmd" in
  init)
    ref="${3:?image ref required}"
    [ -n "${DB_PASSWORD:-}" ] || die "DB_PASSWORD is empty in $ENV_FILE"
    [ -z "$(state_get IMAGE_REF)" ] || die "$ENV_NAME already has a release ($(state_get IMAGE_REF)); use deploy"
    [ -z "$(dc ps -aq)" ] || die "containers exist for $COMPOSE_PROJECT but no release is recorded; inspect: deploy/dc $ENV_NAME ps -a"
    ensure_image "$ref"
    assert_image "$ref"
    USE_REF="$ref"
    dc up -d --remove-orphans
    if in_backend test -f "sites/$SITE_NAME/site_config.json"; then
      die "site $SITE_NAME already exists in the volumes of $COMPOSE_PROJECT; not touching it"
    fi
    if [ -z "${ADMIN_PASSWORD:-}" ]; then
      read -rsp "Administrator password for $SITE_NAME: " ADMIN_PASSWORD; echo
    fi
    log "creating site $SITE_NAME"
    in_backend bench new-site "$SITE_NAME" \
      --mariadb-user-host-login-scope='%' \
      --db-root-password "$DB_PASSWORD" \
      --admin-password "$ADMIN_PASSWORD" \
      --install-app erpnext --install-app "$CUSTOM_APP" \
      --set-default
    in_backend bench --site "$SITE_NAME" scheduler enable
    in_backend bench --site "$SITE_NAME" scheduler resume
    site_checks
    services_ready
    wait_http 200
    write_state "$ref" "" ""
    log "initialised $ENV_NAME on $ref"
    ;;

  deploy)
    ref="${3:?image ref required}"
    FROM_REF="$(state_get IMAGE_REF)"
    [ -n "$FROM_REF" ] || die "no release recorded for $ENV_NAME; use init"
    [ ! -f "$PENDING_FILE" ] || die "an earlier deploy did not finish:
$(cat "$PENDING_FILE")
Restore its backup on FROM_REF (see docs/deployment.md), then remove $PENDING_FILE."
    ensure_image "$ref"
    assert_image "$ref"
    missing_apps "$ref"

    log "closing the site: maintenance mode, stop traffic and background jobs"
    in_backend bench --site "$SITE_NAME" set-maintenance-mode on
    dc stop -t "$STOP_TIMEOUT" frontend websocket queue-short queue-long scheduler
    # A graceful restart lets requests that were already running finish before the backup.
    dc restart -t "$STOP_TIMEOUT" backend

    backup
    mkdir -p "$HERE/state"
    cat > "$PENDING_FILE" <<EOF
CANDIDATE_REF=$ref
FROM_REF=$FROM_REF
BACKUP=$BACKUP_DEST
STARTED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF
    dc stop -t "$STOP_TIMEOUT" backend

    USE_REF="$ref"
    log "migrating with $ref"
    dc run --rm --no-deps -T backend bench --site "$SITE_NAME" migrate || deploy_failed "migration"
    # The custom app may be new to this site (first deploy after adopt).
    if ! dc run --rm --no-deps -T backend bench --site "$SITE_NAME" list-apps | grep -q "^$CUSTOM_APP\b"; then
      log "installing $CUSTOM_APP"
      dc run --rm --no-deps -T backend bench --site "$SITE_NAME" install-app "$CUSTOM_APP" \
        || deploy_failed "installing $CUSTOM_APP"
    fi
    site_checks || deploy_failed "site checks after migration"

    log "starting all services on $ref (site still in maintenance mode)"
    dc up -d --remove-orphans || deploy_failed "starting services"
    services_ready || deploy_failed "services not ready"
    wait_http 503 || deploy_failed "frontend not serving"

    in_backend bench --site "$SITE_NAME" set-maintenance-mode off
    wait_http 200 || deploy_failed "site does not answer after reopening"
    wait_reopened || deploy_failed "site does not answer after reopening"

    write_state "$ref" "$FROM_REF" "$BACKUP_DEST"
    rm -f "$PENDING_FILE"
    log "deployed $ref (previous: $FROM_REF)"
    ;;

  adopt)
    [ -z "$(state_get IMAGE_REF)" ] || die "$ENV_NAME already has a release ($(state_get IMAGE_REF))"
    cid="$(dc ps --status running -q backend)"
    [ -n "$cid" ] || die "no running backend for project $COMPOSE_PROJECT; start the old stack first"
    ref="$(docker inspect -f '{{.Config.Image}}' "$cid")"
    [[ "${ref%%@*}" == *:* ]] || ref="$ref:latest"
    in_backend test -f "sites/$SITE_NAME/site_config.json" || die "site $SITE_NAME not found in $COMPOSE_PROJECT"
    log "apps on $SITE_NAME:"; in_backend bench --site "$SITE_NAME" list-apps
    write_state "$ref" "" ""
    log "adopted $ENV_NAME, current release: $ref"
    log "uninstall apps the new image lacks before deploying (see docs/deployment.md)"
    ;;

  backup) backup ;;

  status)
    cat "$STATE_FILE" 2>/dev/null || echo "no release recorded"
    if [ -f "$PENDING_FILE" ]; then echo "UNFINISHED DEPLOY:"; cat "$PENDING_FILE"; fi
    dc ps
    in_backend cat versions.json 2>/dev/null || true
    echo "ping: HTTP $(http_code)"
    ;;

  *) sed -n '2,15p' "$0"; exit 1 ;;
esac
