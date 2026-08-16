#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCKED_POLICY="$ROOT_DIR/image/config/includes.chroot/usr/share/openclaw-os/policies/locked.json5"
DEFAULT_PATCH="$ROOT_DIR/image/config/includes.chroot/usr/share/openclaw-os/defaults/openclaw.patch.json5"
APPLIANCE_CONFIG="$ROOT_DIR/image/config/includes.chroot/etc/openclaw/appliance.conf"
UPDATE_POLICY="$ROOT_DIR/image/config/includes.chroot/usr/libexec/openclaw-appliance/commands/update-policy.sh"
UPDATE_TRANSACTION="$ROOT_DIR/image/config/includes.chroot/usr/libexec/openclaw-appliance/commands/update-transaction.sh"

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

[[ -f "$LOCKED_POLICY" && ! -L "$LOCKED_POLICY" ]] || fail "locked policy is missing or unsafe"
grep -q 'mode: "all"' "$LOCKED_POLICY" || fail "locked policy must sandbox all sessions"
grep -q 'backend: "docker"' "$LOCKED_POLICY" || fail "locked policy must use the appliance sandbox bridge"
grep -q 'network: "none"' "$LOCKED_POLICY" || fail "locked policy must disable sandbox networking"
grep -q 'readOnlyRoot: true' "$LOCKED_POLICY" || fail "locked policy must use a read-only container root"
grep -q 'capDrop: \["ALL"\]' "$LOCKED_POLICY" || fail "locked policy must drop all container capabilities"
grep -A3 'elevated:' "$LOCKED_POLICY" | grep -q 'enabled: false' || fail "locked policy must disable elevated execution"

grep -q 'checkOnStart: false' "$DEFAULT_PATCH" || fail "OpenClaw startup update checks must remain disabled"
grep -A3 'auto:' "$DEFAULT_PATCH" | grep -q 'enabled: false' || fail "OpenClaw background updates must remain disabled"
grep -q '^OPENCLAW_UPDATE_POLICY=tested-only$' "$APPLIANCE_CONFIG" || fail "safe update policy must be the default"
grep -q 'requested_spec.*version' "$UPDATE_POLICY" || fail "untested releases must require an exact version"
grep -q 'gateway_was_active' "$UPDATE_TRANSACTION" || fail "release activation must preserve Gateway service state"

echo "Policy tests passed."
