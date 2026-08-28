#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

export OPENCLAW_RELEASES_DIR="$TEST_ROOT/releases"
export OPENCLAW_CURRENT_LINK="$TEST_ROOT/current"
export OPENCLAW_CONFIG_FILE="$TEST_ROOT/state/openclaw.json"
export OPENCLAW_COMPATIBILITY_FILE="$TEST_ROOT/openclaw-compatibility.json"
export OPENCLAW_UPDATE_STATE_DIR="$TEST_ROOT/update-state"
export OPENCLAW_PENDING_UPDATE_FILE="$OPENCLAW_UPDATE_STATE_DIR/pending.json"
export OPENCLAW_RELEASE_LOCK_FILE="$TEST_ROOT/release.lock"
export RELEASE_ENV_FILE="$TEST_ROOT/release.env"
export APPLIANCE_CONFIG_FILE="$TEST_ROOT/appliance.conf"
export NODE_CURRENT_LINK="$TEST_ROOT/node/current"

log() { :; }
warn() { :; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
require_root() { :; }
ensure_runtime_directory() { :; }
load_release_env() {
  # shellcheck disable=SC1090
  source "$RELEASE_ENV_FILE"
}
load_appliance_config() {
  UPDATE_CHANNEL=extended-stable
  # Consumed by the sourced release-pruning function.
  # shellcheck disable=SC2034
  KEEP_OPENCLAW_RELEASES=3
  OPENCLAW_UPDATE_POLICY=tested-only
  if [[ -r "$APPLIANCE_CONFIG_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$APPLIANCE_CONFIG_FILE"
  fi
}
config_exists() { [[ -f "$OPENCLAW_CONFIG_FILE" ]]; }
run_openclaw() { return "${RUN_OPENCLAW_RC:-0}"; }
run_openclaw_bin() { return 0; }
wait_for_gateway_health() { return 0; }
command_backup() { :; }
install_openclaw_release() { :; }
resolve_npm_metadata() { :; }

# shellcheck disable=SC1090
source "$ROOT_DIR/image/config/includes.chroot/usr/libexec/openclaw-appliance/commands/releases.sh"

cat >"$RELEASE_ENV_FILE" <<'ENV'
OPENCLAW_OS_VERSION=0.1.0-alpha.1
ENV
cat >"$OPENCLAW_COMPATIBILITY_FILE" <<'JSON'
{
  "schemaVersion": 1,
  "openclawOsVersion": "0.1.0-alpha.1",
  "testedOpenclawVersions": ["2026.6.34", "2026.7.1"]
}
JSON
: >"$APPLIANCE_CONFIG_FILE"

[[ "$(openclaw_version_compatibility 2026.6.34)" == "tested" ]] || \
  die "Tested OpenClaw version was not recognized"
[[ "$(openclaw_version_compatibility 2026.8.0)" == "untested" ]] || \
  die "Untested OpenClaw version was accepted as tested"

load_update_config
if (require_resolved_update_authorization 2026.8.0 extended-stable yes untested) >/dev/null 2>&1; then
  die "A moving npm tag bypassed the untested-release gate"
fi
if (require_resolved_update_authorization 2026.8.0 2026.8.0 no untested) >/dev/null 2>&1; then
  die "Untested exact release was accepted without acknowledgement"
fi
require_resolved_update_authorization 2026.8.0 2026.8.0 yes untested
printf 'OPENCLAW_UPDATE_POLICY=allow-untested-exact\n' >"$APPLIANCE_CONFIG_FILE"
load_update_config
require_resolved_update_authorization 2026.8.0 2026.8.0 no untested

parse_update_arguments check extended-stable
[[ "$UPDATE_ACTION" == "check" && "$UPDATE_SPEC" == "extended-stable" ]] || \
  die "Update check arguments were parsed incorrectly"
parse_update_arguments stage 2026.7.1
[[ "$UPDATE_ACTION" == "stage" && "$UPDATE_SPEC" == "2026.7.1" ]] || \
  die "Update stage arguments were parsed incorrectly"
parse_update_arguments apply 2026.8.0 --allow-untested
[[ "$UPDATE_ACTION" == "apply" && "$UPDATE_SPEC" == "2026.8.0" && "$UPDATE_ALLOW_UNTESTED" == "yes" ]] || \
  die "Update apply acknowledgement was parsed incorrectly"
parse_update_arguments extended-stable
[[ "$UPDATE_ACTION" == "apply" && "$UPDATE_SPEC" == "extended-stable" ]] || \
  die "Legacy update syntax no longer maps to apply"

mkdir -p "$OPENCLAW_UPDATE_STATE_DIR" "$OPENCLAW_RELEASES_DIR/2026.7.1/bin"
cat >"$OPENCLAW_PENDING_UPDATE_FILE" <<'JSON'
{
  "schemaVersion": 1,
  "openclawOsVersion": "0.1.0-alpha.1",
  "version": "2026.7.1",
  "integrity": "sha512-VGVzdA==",
  "tarball": "https://registry.npmjs.org/openclaw/-/openclaw-2026.7.1.tgz",
  "requestedSpec": "2026.7.1",
  "compatibility": "tested",
  "stagedAt": "2026-08-16T02:00:00Z"
}
JSON
load_pending_update
[[ "$PENDING_VERSION" == "2026.7.1" && "$PENDING_COMPATIBILITY" == "tested" ]] || \
  die "Pending update metadata did not load"
use_pending_candidate ""
[[ "$RESOLVED_VERSION" == "2026.7.1" && "$RESOLVED_REQUESTED_SPEC" == "2026.7.1" ]] || \
  die "Pending exact candidate was not selected"

mkdir -p \
  "$OPENCLAW_RELEASES_DIR/2026.6.34/bin" \
  "$OPENCLAW_RELEASES_DIR/2026.7.1/bin" \
  "$(dirname "$OPENCLAW_CONFIG_FILE")"
printf '#!/bin/sh\nexit 0\n' >"$OPENCLAW_RELEASES_DIR/2026.6.34/bin/openclaw"
printf '#!/bin/sh\nexit 0\n' >"$OPENCLAW_RELEASES_DIR/2026.7.1/bin/openclaw"
chmod +x "$OPENCLAW_RELEASES_DIR/2026.6.34/bin/openclaw" "$OPENCLAW_RELEASES_DIR/2026.7.1/bin/openclaw"
printf '{}\n' >"$OPENCLAW_CONFIG_FILE"
ln -s "$OPENCLAW_RELEASES_DIR/2026.6.34" "$OPENCLAW_CURRENT_LINK"

SYSTEMCTL_LOG="$TEST_ROOT/systemctl.log"
systemctl() {
  printf '%s\n' "$*" >>"$SYSTEMCTL_LOG"
  return 0
}

: >"$SYSTEMCTL_LOG"
activate_release \
  "$OPENCLAW_RELEASES_DIR/2026.7.1" \
  "$OPENCLAW_RELEASES_DIR/2026.6.34" \
  no
[[ "$(readlink -f "$OPENCLAW_CURRENT_LINK")" == "$OPENCLAW_RELEASES_DIR/2026.7.1" ]] || \
  die "Inactive Gateway activation did not switch releases"
if grep -Eq '^(start|restart) openclaw.service$' "$SYSTEMCTL_LOG"; then
  die "Inactive Gateway was unexpectedly started during activation"
fi

ln -sfn "$OPENCLAW_RELEASES_DIR/2026.6.34" "$OPENCLAW_CURRENT_LINK"
: >"$SYSTEMCTL_LOG"
HEALTH_CALLS=0
wait_for_gateway_health() {
  HEALTH_CALLS=$((HEALTH_CALLS + 1))
  ((HEALTH_CALLS > 1))
}
if activate_release \
  "$OPENCLAW_RELEASES_DIR/2026.7.1" \
  "$OPENCLAW_RELEASES_DIR/2026.6.34" \
  yes; then
  die "Unhealthy candidate release remained active"
fi
[[ "$(readlink -f "$OPENCLAW_CURRENT_LINK")" == "$OPENCLAW_RELEASES_DIR/2026.6.34" ]] || \
  die "Failed candidate did not restore the previous release"
[[ "$(grep -c '^restart openclaw.service$' "$SYSTEMCTL_LOG")" -eq 2 ]] || \
  die "Gateway restart sequence did not include candidate and rollback starts"

echo "Update tests passed."
