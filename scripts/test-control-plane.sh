#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NODE_BIN="${NODE_BIN:-node}"

command -v "$NODE_BIN" >/dev/null 2>&1 || {
  echo "Node.js is required for control-plane tests" >&2
  exit 1
}
node_version="$($NODE_BIN --version)"
node_major="${node_version#v}"
node_major="${node_major%%.*}"
if [[ ! "$node_major" =~ ^[0-9]+$ ]] || ((node_major < 24)); then
  echo "Control-plane tests require Node.js 24 or newer, found $node_version" >&2
  exit 1
fi

cd "$ROOT_DIR"
exec "$NODE_BIN" --experimental-strip-types --test tests/control-plane/*.test.ts
