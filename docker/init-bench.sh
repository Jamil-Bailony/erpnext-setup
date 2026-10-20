#!/usr/bin/env bash
# Idempotent dev bench setup from versions.env + apps.json. Runs inside the frappe container:
#   ./dev init        create what is missing; warn when upstream apps drift from the pins
#   ./dev sync        same, but move drifted upstream apps to their pinned tags and migrate
# Safe to re-run. The custom app is a symlink to /workspace/apps/<CUSTOM_APP> (this repo),
# so edits in the repo are live in the bench, and DocTypes saved in developer mode land there.
set -euo pipefail

source /workspace/versions.env
SITE="${SITE:-erp.localhost}"
TEST_SITE="${TEST_SITE:-test.localhost}"
DB_ROOT_PASSWORD="${DB_ROOT_PASSWORD:-123}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-admin}"
WEB_PORT="${DEV_WEB_PORT:-8001}"
SOCKETIO_PORT="${DEV_SOCKETIO_PORT:-9001}"
BENCH_DIR=/workspace/development/frappe-bench

die() { echo "ERROR: $*" >&2; exit 1; }
warn() { echo "WARNING: $*" >&2; }

SYNC="${SYNC:-0}"
CHANGED=0
# Written when an app moves, removed after requirements, build and migrate succeed, so a run
# that failed half-way redoes them next time.
PENDING="$BENCH_DIR/.sync-pending"

# Upstream app not at its pinned ref: warn, or with SYNC=1 fetch and check out the pin.
# A ref like v16.1.0 is a tag (fixed); anything else is a branch, which sync moves to its tip.
check_ref() {
  local app="$1" ref="$2" head
  head="$(git -C "apps/$app" rev-parse HEAD)"
  if ! [[ "$ref" =~ ^v[0-9]+\. ]]; then
    [ "$SYNC" = 1 ] || return 0
    git -C "apps/$app" fetch --quiet --depth 1 upstream "$ref"
    if [ "$head" != "$(git -C "apps/$app" rev-parse FETCH_HEAD)" ]; then
      echo "==> $app -> tip of $ref"
      touch "$PENDING"
      git -C "apps/$app" checkout --quiet -B "$ref" FETCH_HEAD
      CHANGED=1
    fi
    return 0
  fi
  if [ "$head" = "$(git -C "apps/$app" rev-parse -q --verify "$ref^{commit}" 2>/dev/null)" ]; then
    return
  fi
  if [ "$SYNC" = 1 ]; then
    [ -z "$(git -C "apps/$app" status --porcelain --untracked-files=no)" ] \
      || die "apps/$app has local changes; refusing to move it to $ref"
    echo "==> $app -> $ref"
    git -C "apps/$app" fetch --depth 1 upstream tag "$ref"
    touch "$PENDING"
    git -C "apps/$app" checkout --quiet "$ref"
    CHANGED=1
  else
    warn "$app is at $(git -C "apps/$app" describe --tags --always) but versions pin $ref (run ./dev sync)"
  fi
}

# --- bench --------------------------------------------------------------------------------
if [ -d "$BENCH_DIR" ] && [ ! -x "$BENCH_DIR/env/bin/python" ]; then
  die "$BENCH_DIR exists but has no virtualenv (interrupted init?). Remove it and re-run."
fi
if [ ! -d "$BENCH_DIR" ]; then
  bench init --skip-redis-config-generation --frappe-branch "$FRAPPE_REF" --python python3.14 "$BENCH_DIR"
fi
cd "$BENCH_DIR"
[ -f "$PENDING" ] && { echo "==> finishing an earlier sync"; CHANGED=1; }
check_ref frappe "$FRAPPE_REF"

# Point the bench at the compose services instead of local redis/mariadb.
bench set-config -g db_host mariadb
bench set-config -g redis_cache redis://redis-cache:6379
bench set-config -g redis_queue redis://redis-queue:6379
bench set-config -g redis_socketio redis://redis-queue:6379
bench set-config -g -p webserver_port "$WEB_PORT"
bench set-config -g -p socketio_port "$SOCKETIO_PORT"
rm -f Procfile && bench setup procfile
sed -i '/redis/d' Procfile
# Outgoing mail goes to mailpit unless a site has its own default Email Account.
bench set-config -g mail_server mailpit
bench set-config -g -p mail_port 1025
bench set-config -g -p disable_mail_smtp_authentication 1
bench set-config -g auto_email_id dev@erp.localhost

# --- apps ---------------------------------------------------------------------------------
# The folder is the app's name, which can differ from the repo name
# (erpnext-arabic-full-translation -> arabic_translations), so find it by its git remote.
app_dir_for() {
  local d
  for d in apps/*/; do
    [ "$(git -C "$d" remote get-url upstream 2>/dev/null)" = "$1" ] && { basename "$d"; return; }
  done
  return 0
}

get_app() {
  local url="$1" ref="$2" app
  app="$(app_dir_for "$url")"
  if [ -z "$app" ]; then
    bench get-app --branch "$ref" "$url"
  elif ! grep -qx "$app" sites/apps.txt; then
    die "apps/$app exists but is not registered in sites/apps.txt (interrupted get-app?). Remove apps/$app and re-run."
  else
    check_ref "$app" "$ref"
  fi
}

while read -r url ref; do
  get_app "$url" "$ref"
done < <(python3 -c '
import json
for a in json.load(open("/workspace/apps.json")):
    print(a["url"], a["branch"])
')

# The custom app lives in this repo; link it instead of cloning (what `get-app --soft-link`
# does, without needing the app to be its own git repo).
[ -e "apps/$CUSTOM_APP" ] || ln -s "/workspace/apps/$CUSTOM_APP" "apps/$CUSTOM_APP"
if ! grep -qx "$CUSTOM_APP" sites/apps.txt; then
  bench pip install --quiet -e "apps/$CUSTOM_APP"
  python3 - "$CUSTOM_APP" <<'PY'
import sys
path = "sites/apps.txt"
apps = [a for a in open(path).read().split() if a]
apps.append(sys.argv[1])
open(path, "w").write("\n".join(apps) + "\n")
PY
  bench build --app "$CUSTOM_APP"
fi

if [ "$CHANGED" = 1 ]; then
  bench setup requirements
  bench build
fi

# --- sites --------------------------------------------------------------------------------
# $SITE is where you work. $TEST_SITE only runs tests, so they never touch your working data.
setup_site() {
  local site="$1" installed app
  if [ ! -f "sites/$site/site_config.json" ]; then
    bench new-site "$site" \
      --mariadb-user-host-login-scope='%' \
      --db-root-password "$DB_ROOT_PASSWORD" \
      --admin-password "$ADMIN_PASSWORD"
  elif ! bench --site "$site" list-apps >/dev/null 2>&1; then
    die "sites/$site exists but the site does not load. Fix it or run: bench drop-site $site --force"
  fi
  installed="$(bench --site "$site" list-apps)"
  for app in $(cat sites/apps.txt); do
    grep -q "^$app\b" <<<"$installed" || bench --site "$site" install-app "$app"
  done
  bench --site "$site" set-config developer_mode 1
  bench --site "$site" set-config allow_tests true
}

setup_site "$SITE"
setup_site "$TEST_SITE"
# New sites start with the scheduler off; the working site needs it for queued mail and jobs.
bench --site "$SITE" scheduler enable >/dev/null

if [ "$CHANGED" = 1 ]; then
  bench --site all migrate
  rm -f "$PENDING"
fi

bench use "$SITE"

echo "Bench ready. Run ./dev start, then open http://$SITE:$WEB_PORT (user Administrator)."
