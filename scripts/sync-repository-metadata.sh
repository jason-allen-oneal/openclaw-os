#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
METADATA_FILE="$ROOT_DIR/.github/repository-metadata.json"

command -v gh >/dev/null 2>&1 || {
  echo "GitHub CLI is required." >&2
  exit 1
}
command -v jq >/dev/null 2>&1 || {
  echo "jq is required." >&2
  exit 1
}
[[ -f "$METADATA_FILE" && ! -L "$METADATA_FILE" ]] || {
  echo "Repository metadata file is missing or unsafe." >&2
  exit 1
}

gh auth status >/dev/null
repository="$(jq -er '.repository' "$METADATA_FILE")"
description="$(jq -er '.description' "$METADATA_FILE")"
homepage="$(jq -er '.homepage' "$METADATA_FILE")"
current_repository="$(gh repo view --json nameWithOwner --jq '.nameWithOwner')"
[[ "$current_repository" == "$repository" ]] || {
  printf 'Refusing to update %s from metadata for %s.\n' "$current_repository" "$repository" >&2
  exit 1
}

gh api \
  --method PATCH \
  "repos/$repository" \
  -f "description=$description" \
  -f "homepage=$homepage" \
  >/dev/null

jq '{names: .topics}' "$METADATA_FILE" | gh api \
  --method PUT \
  -H 'Accept: application/vnd.github+json' \
  "repos/$repository/topics" \
  --input - \
  >/dev/null

printf 'Synchronized GitHub metadata for %s.\n' "$repository"
