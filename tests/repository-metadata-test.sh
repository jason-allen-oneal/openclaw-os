#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
METADATA_FILE="$ROOT_DIR/.github/repository-metadata.json"
README_FILE="$ROOT_DIR/README.md"

[[ -f "$METADATA_FILE" && ! -L "$METADATA_FILE" ]] || {
  echo "Repository metadata file is missing or unsafe." >&2
  exit 1
}

jq -e '
  .repository == "jason-allen-oneal/openclaw-os" and
  (.description | type == "string" and length >= 20 and length <= 160) and
  (.homepage | type == "string" and startswith("https://")) and
  (.topics | type == "array" and length >= 4 and length <= 20) and
  (.topics | all(type == "string" and test("^[a-z0-9-]+$"))) and
  ((.topics | unique | length) == (.topics | length))
' "$METADATA_FILE" >/dev/null || {
  echo "Repository metadata schema is invalid." >&2
  exit 1
}

grep -q '^# OpenClaw OS$' "$README_FILE" || {
  echo "README title is missing." >&2
  exit 1
}
grep -q '^## Safe OpenClaw upgrades$' "$README_FILE" || {
  echo "README does not document safe OpenClaw upgrades." >&2
  exit 1
}
grep -q 'docs/UPDATES.md' "$README_FILE" || {
  echo "README does not link to the update runbook." >&2
  exit 1
}

echo "Repository metadata tests passed."
