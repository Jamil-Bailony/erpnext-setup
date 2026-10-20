#!/usr/bin/env bash
# Build the release image from versions.env + apps.json + apps/<CUSTOM_APP>.
#
#   scripts/build-image.sh                         # local, this machine's arch: erp:<repo-sha>
#   PLATFORM=linux/arm64 scripts/build-image.sh    # cross-build (needs QEMU; slow)
#   IMAGE=ghcr.io/me/erp TAG=x scripts/build-image.sh --push
#
# CI (.github/workflows/build.yml) does the real arm64/amd64 builds; this is for testing
# changes on a PC before pushing. Uncommitted changes are built too, and the tag says so.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/versions.env"

[ -f "$ROOT/deploy/frappe_docker/resources/core/start.sh" ] \
  || { echo "frappe_docker submodule missing: git submodule update --init" >&2; exit 1; }

rev="$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo nocommit)"
[ -z "$(git -C "$ROOT" status --porcelain -- apps images apps.json versions.env 2>/dev/null)" ] || rev="$rev-dirty"
IMAGE="${IMAGE:-erp}"
TAG="${TAG:-$rev}"
OUTPUT=(--load)
[ "${1:-}" = "--push" ] && OUTPUT=(--push)
PLATFORM_ARGS=()
[ -n "${PLATFORM:-}" ] && PLATFORM_ARGS=(--platform "$PLATFORM")

docker buildx build \
  --file "$ROOT/images/Containerfile" \
  --build-arg "BUILD_IMAGE=$BUILD_IMAGE" \
  --build-arg "BASE_IMAGE=$BASE_IMAGE" \
  --build-arg "FRAPPE_REF=$FRAPPE_REF" \
  --build-arg "CUSTOM_APP=$CUSTOM_APP" \
  --build-arg "REPO_REV=$rev" \
  --label "org.opencontainers.image.revision=$rev" \
  --label "erp.frappe.ref=$FRAPPE_REF" \
  --tag "$IMAGE:$TAG" \
  "${PLATFORM_ARGS[@]}" \
  "${OUTPUT[@]}" \
  "$ROOT"

echo "Built $IMAGE:$TAG"
