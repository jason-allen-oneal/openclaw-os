#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FILTER="$ROOT_DIR/scripts/iso-build-required.sh"

[[ -x "$FILTER" ]] || {
  echo "ISO build change filter is missing or not executable: $FILTER" >&2
  exit 1
}

run_case() {
  local expected="$1"
  local label="$2"
  shift 2

  local payload actual
  payload="$(mktemp)"
  trap 'rm -f "$payload"' RETURN

  if (($# > 0)); then
    printf '%s\0' "$@" >"$payload"
  fi

  actual="$("$FILTER" <"$payload")"
  if [[ "$actual" != "$expected" ]]; then
    printf 'Case %s expected %s, got %s.\n' "$label" "$expected" "$actual" >&2
    exit 1
  fi

  rm -f "$payload"
  trap - RETURN
}

run_case false "documentation only" \
  README.md \
  SECURITY.md \
  docs/ARCHITECTURE.md \
  "docs/design notes.md"

run_case false "repository administration only" \
  .github/repository-metadata.json \
  config/repository-protection.json \
  .github/workflows/delete-merged-branches.yml

run_case true "build workflow" \
  .github/workflows/build-iso.yml

run_case true "image source" \
  image/config/package-lists/openclaw-os.list.chroot

run_case true "runtime source" \
  services/controller/src/server.ts

run_case true "unknown path fails safe" \
  future-component/config.json

run_case true "mixed documentation and image source" \
  README.md \
  image/config/bootloaders/grub-pc/grub.cfg

run_case true "empty comparison fails safe"

echo "ISO change-filter tests passed."
