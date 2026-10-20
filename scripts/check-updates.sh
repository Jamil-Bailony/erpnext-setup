#!/usr/bin/env bash
# Report newer upstream releases for everything versions.env, apps.json and the frappe_docker
# submodule pin, within the current major version. With --apply, write the new pins.
#
#   scripts/check-updates.sh            # report only
#   scripts/check-updates.sh --apply    # update pins, then follow the printed next steps
#
# Never crosses a major version (v16 -> v17 is a planned project, not a routine update).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APPLY=0; [ "${1:-}" = "--apply" ] && APPLY=1
source "$ROOT/versions.env"
FD="$ROOT/deploy/frappe_docker"
MAJOR="$(sed -E 's/^v([0-9]+)\..*/\1/' <<<"$FRAPPE_REF")"

# Highest vX.Y.Z tag of a git repo, optionally limited to a major version.
latest_tag() {
  local url="$1" major="${2:-}"
  git ls-remote --tags --refs "$url" "v${major}${major:+.}*" \
    | sed 's|.*refs/tags/||' | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -1
}

# Docker Hub: highest vX.Y.Z tag, or the digest of a named tag.
hub() {
  python3 - "$@" <<'EOF'
import json, re, sys, urllib.request
repo, mode = sys.argv[1], sys.argv[2]
base = f"https://hub.docker.com/v2/repositories/{repo}/tags"
if mode == "latest":
    data = json.load(urllib.request.urlopen(f"{base}?page_size=100&ordering=last_updated"))
    tags = [t["name"] for t in data["results"] if re.fullmatch(r"v\d+\.\d+\.\d+", t["name"])]
    print(max(tags, key=lambda t: tuple(map(int, t[1:].split(".")))))
else:
    print(json.load(urllib.request.urlopen(f"{base}/{mode}"))["digest"])
EOF
}

declare -A cur new
cur[frappe]="$FRAPPE_REF"
new[frappe]="$(latest_tag https://github.com/frappe/frappe "$MAJOR")"
while read -r app url ref; do
  cur[$app]="$ref"; new[$app]="$(latest_tag "$url" "$MAJOR")"
done < <(python3 -c '
import json
for a in json.load(open("'"$ROOT"'/apps.json")):
    print(a["url"].rstrip("/").removesuffix(".git").rsplit("/", 1)[-1], a["url"], a["branch"])')

cur[frappe_docker]="$(git -C "$FD" describe --tags --exact-match 2>/dev/null || git -C "$FD" rev-parse --short HEAD)"
new[frappe_docker]="$(latest_tag https://github.com/frappe/frappe_docker)"
cur[bench_image]="${BENCH_IMAGE##*:}"
new[bench_image]="$(hub frappe/bench latest)"
cur[build_image]="${BUILD_IMAGE##*@}"
new[build_image]="$(hub frappe/build "version-$MAJOR")"
cur[base_image]="${BASE_IMAGE##*@}"
new[base_image]="$(hub frappe/base "version-$MAJOR")"

printf '%-14s %-24s %-24s\n' component pinned latest
updates=0
for k in frappe $(python3 -c 'import json; print(" ".join(a["url"].rstrip("/").rsplit("/",1)[-1] for a in json.load(open("'"$ROOT"'/apps.json"))))') frappe_docker bench_image build_image base_image; do
  mark=""; [ "${cur[$k]}" != "${new[$k]}" ] && { mark="  <- update"; updates=1; }
  printf '%-14s %-24.24s %-24.24s%s\n' "$k" "${cur[$k]}" "${new[$k]}" "$mark"
done

[ "$updates" = 1 ] || { echo "Everything is at the latest v$MAJOR release."; exit 0; }
[ "$APPLY" = 1 ] || { echo; echo "Run with --apply to update the pins."; exit 0; }

# --- apply -----------------------------------------------------------------------------------
sed -i \
  -e "s|^FRAPPE_REF=.*|FRAPPE_REF=${new[frappe]}|" \
  -e "s|^BENCH_IMAGE=.*|BENCH_IMAGE=${BENCH_IMAGE%:*}:${new[bench_image]}|" \
  -e "s|^BUILD_IMAGE=.*|BUILD_IMAGE=${BUILD_IMAGE%@*}@${new[build_image]}|" \
  -e "s|^BASE_IMAGE=.*|BASE_IMAGE=${BASE_IMAGE%@*}@${new[base_image]}|" \
  "$ROOT/versions.env"

for app in "${!new[@]}"; do echo "$app ${new[$app]}"; done | python3 -c '
import json, sys
new = dict(l.split() for l in sys.stdin)
path = "'"$ROOT"'/apps.json"
apps = json.load(open(path))
for a in apps:
    name = a["url"].rstrip("/").removesuffix(".git").rsplit("/", 1)[-1]
    a["branch"] = new.get(name, a["branch"])
with open(path, "w") as f:
    f.write("[\n" + ",\n".join("  " + json.dumps(a) for a in apps) + "\n]\n")'

old_fd="$(git -C "$FD" rev-parse HEAD)"
if [ "${cur[frappe_docker]}" != "${new[frappe_docker]}" ]; then
  git -C "$FD" fetch --quiet --tags origin
  git -C "$FD" checkout --quiet "${new[frappe_docker]}"
  echo
  echo "frappe_docker ${cur[frappe_docker]} -> ${new[frappe_docker]}: files we depend on that changed"
  echo "(port relevant changes of images/layered/Containerfile into images/Containerfile):"
  git -C "$FD" diff --stat "$old_fd" HEAD -- \
    compose.yaml overrides/compose.mariadb.yaml overrides/compose.redis.yaml \
    overrides/compose.noproxy.yaml overrides/compose.https.yaml \
    images/layered/Containerfile resources/core || true
fi

cat <<EOF

Pins updated. Next:
  1. Read the release notes (frappe, erpnext on GitHub) for anything that touches erp_custom.
  2. ./dev sync                      # dev bench to the new versions + migrate
  3. ./dev test --app erp_custom     # and click through the screens you customised
  4. Commit versions.env, apps.json and deploy/frappe_docker; push -> CI builds and verifies.
  5. deploy/deploy.sh deploy pi <image-ref from the run summary>
EOF
