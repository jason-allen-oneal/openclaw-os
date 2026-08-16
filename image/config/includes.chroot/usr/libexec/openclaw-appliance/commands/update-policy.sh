# shellcheck shell=bash

OPENCLAW_COMPATIBILITY_FILE="${OPENCLAW_COMPATIBILITY_FILE:-/usr/lib/openclaw-os/control-plane/config/openclaw-compatibility.json}"
OPENCLAW_UPDATE_STATE_DIR="${OPENCLAW_UPDATE_STATE_DIR:-/var/lib/openclaw/update-state}"
OPENCLAW_PENDING_UPDATE_FILE="${OPENCLAW_PENDING_UPDATE_FILE:-$OPENCLAW_UPDATE_STATE_DIR/pending.json}"
OPENCLAW_RELEASE_LOCK_FILE="${OPENCLAW_RELEASE_LOCK_FILE:-/run/openclaw/release.lock}"

active_release_target() {
  if [[ ! -e "$OPENCLAW_CURRENT_LINK" && ! -L "$OPENCLAW_CURRENT_LINK" ]]; then
    printf '\n'
    return 0
  fi
  [[ -L "$OPENCLAW_CURRENT_LINK" ]] || die "Active OpenClaw path is not a symbolic link"

  local resolved
  resolved="$(readlink -f "$OPENCLAW_CURRENT_LINK" 2>/dev/null || true)"
  [[ -n "$resolved" && -d "$resolved" ]] || die "Active OpenClaw release cannot be resolved"
  [[ "$resolved" == "$OPENCLAW_RELEASES_DIR/"* ]] || \
    die "Active OpenClaw release is outside $OPENCLAW_RELEASES_DIR"
  printf '%s\n' "$resolved"
}

load_update_config() {
  load_appliance_config
  OPENCLAW_UPDATE_POLICY="${OPENCLAW_UPDATE_POLICY:-tested-only}"
  case "$OPENCLAW_UPDATE_POLICY" in
    tested-only|allow-untested-exact) ;;
    *) die "OPENCLAW_UPDATE_POLICY must be tested-only or allow-untested-exact" ;;
  esac
}

validate_compatibility_manifest() {
  [[ -f "$OPENCLAW_COMPATIBILITY_FILE" && ! -L "$OPENCLAW_COMPATIBILITY_FILE" ]] || \
    die "OpenClaw compatibility manifest is missing or unsafe: $OPENCLAW_COMPATIBILITY_FILE"

  local manifest_size
  manifest_size="$(stat -c '%s' "$OPENCLAW_COMPATIBILITY_FILE" 2>/dev/null || true)"
  [[ "$manifest_size" =~ ^[0-9]+$ ]] || die "Cannot inspect the OpenClaw compatibility manifest"
  ((manifest_size <= 65536)) || die "OpenClaw compatibility manifest is too large"

  jq -e '
    .schemaVersion == 1 and
    (.openclawOsVersion | type == "string" and length > 0) and
    (.testedOpenclawVersions | type == "array" and length > 0) and
    (.testedOpenclawVersions | all(type == "string" and length > 0))
  ' "$OPENCLAW_COMPATIBILITY_FILE" >/dev/null || \
    die "OpenClaw compatibility manifest schema is invalid"

  load_release_env
  local manifest_os_version
  manifest_os_version="$(jq -r '.openclawOsVersion' "$OPENCLAW_COMPATIBILITY_FILE")"
  [[ "$manifest_os_version" == "$OPENCLAW_OS_VERSION" ]] || \
    die "Compatibility manifest is for OpenClaw OS $manifest_os_version, not $OPENCLAW_OS_VERSION"
}

openclaw_version_compatibility() {
  local version="$1"
  [[ "$version" =~ ^[0-9A-Za-z._+-]+$ ]] || die "Unsafe OpenClaw version string: $version"
  validate_compatibility_manifest
  if jq -e --arg version "$version" '.testedOpenclawVersions | index($version) != null' \
    "$OPENCLAW_COMPATIBILITY_FILE" >/dev/null; then
    printf 'tested\n'
  else
    printf 'untested\n'
  fi
}

require_resolved_update_authorization() {
  local version="$1"
  local requested_spec="$2"
  local allow_untested="$3"
  local compatibility="$4"

  [[ "$compatibility" == "tested" || "$compatibility" == "untested" ]] || \
    die "Unknown compatibility result: $compatibility"
  [[ "$compatibility" == "tested" ]] && return 0

  [[ "$requested_spec" == "$version" ]] || die \
    "OpenClaw $version is untested on this OpenClaw OS release. Untested releases must be requested by exact version, not by a moving npm tag."

  if [[ "$allow_untested" == "yes" || "$OPENCLAW_UPDATE_POLICY" == "allow-untested-exact" ]]; then
    warn "Activating untested OpenClaw $version by explicit operator policy"
    return 0
  fi

  die "OpenClaw $version is not in this image's tested compatibility set. Re-run with the exact version and --allow-untested, or set OPENCLAW_UPDATE_POLICY=allow-untested-exact."
}

pending_update_exists() {
  [[ -e "$OPENCLAW_PENDING_UPDATE_FILE" ]]
}

load_pending_update() {
  [[ -f "$OPENCLAW_PENDING_UPDATE_FILE" && ! -L "$OPENCLAW_PENDING_UPDATE_FILE" ]] || \
    die "Pending update metadata is missing or unsafe"

  local pending_size
  pending_size="$(stat -c '%s' "$OPENCLAW_PENDING_UPDATE_FILE" 2>/dev/null || true)"
  [[ "$pending_size" =~ ^[0-9]+$ ]] || die "Cannot inspect pending update metadata"
  ((pending_size <= 16384)) || die "Pending update metadata is too large"

  jq -e '
    .schemaVersion == 1 and
    (.openclawOsVersion | type == "string" and length > 0) and
    (.version | type == "string" and test("^[0-9A-Za-z._+-]+$")) and
    (.integrity | type == "string" and test("^sha512-[A-Za-z0-9+/=]+$")) and
    (.tarball | type == "string" and startswith("https://registry.npmjs.org/openclaw/-/openclaw-")) and
    (.requestedSpec | type == "string" and test("^[0-9A-Za-z._+-]+$")) and
    (.compatibility == "tested" or .compatibility == "untested") and
    (.stagedAt | type == "string" and length > 0)
  ' "$OPENCLAW_PENDING_UPDATE_FILE" >/dev/null || die "Pending update metadata is invalid"

  load_release_env
  PENDING_OS_VERSION="$(jq -r '.openclawOsVersion' "$OPENCLAW_PENDING_UPDATE_FILE")"
  PENDING_VERSION="$(jq -r '.version' "$OPENCLAW_PENDING_UPDATE_FILE")"
  PENDING_INTEGRITY="$(jq -r '.integrity' "$OPENCLAW_PENDING_UPDATE_FILE")"
  PENDING_TARBALL="$(jq -r '.tarball' "$OPENCLAW_PENDING_UPDATE_FILE")"
  PENDING_REQUESTED_SPEC="$(jq -r '.requestedSpec' "$OPENCLAW_PENDING_UPDATE_FILE")"
  PENDING_COMPATIBILITY="$(jq -r '.compatibility' "$OPENCLAW_PENDING_UPDATE_FILE")"
  PENDING_STAGED_AT="$(jq -r '.stagedAt' "$OPENCLAW_PENDING_UPDATE_FILE")"

  [[ "$PENDING_OS_VERSION" == "$OPENCLAW_OS_VERSION" ]] || \
    die "Pending update belongs to OpenClaw OS $PENDING_OS_VERSION, not $OPENCLAW_OS_VERSION"
  [[ "$PENDING_TARBALL" == "https://registry.npmjs.org/openclaw/-/openclaw-${PENDING_VERSION}.tgz" ]] || \
    die "Pending update tarball does not match its version"
}

write_pending_update() (
  set -Eeuo pipefail
  local version="$1"
  local integrity="$2"
  local tarball="$3"
  local requested_spec="$4"
  local compatibility="$5"

  require_root
  load_release_env
  install -d -m 0700 -o root -g root "$OPENCLAW_UPDATE_STATE_DIR"

  local temporary
  temporary="$(mktemp "$OPENCLAW_UPDATE_STATE_DIR/.pending.XXXXXX")"
  trap 'rm -f "$temporary"' EXIT
  jq -n \
    --arg osVersion "$OPENCLAW_OS_VERSION" \
    --arg version "$version" \
    --arg integrity "$integrity" \
    --arg tarball "$tarball" \
    --arg requestedSpec "$requested_spec" \
    --arg compatibility "$compatibility" \
    --arg stagedAt "$(date --utc +%Y-%m-%dT%H:%M:%SZ)" \
    '{
      schemaVersion: 1,
      openclawOsVersion: $osVersion,
      version: $version,
      integrity: $integrity,
      tarball: $tarball,
      requestedSpec: $requestedSpec,
      compatibility: $compatibility,
      stagedAt: $stagedAt
    }' >"$temporary"
  chmod 0600 "$temporary"
  chown root:root "$temporary"
  mv -fT "$temporary" "$OPENCLAW_PENDING_UPDATE_FILE"
)

clear_pending_update() {
  require_root
  if [[ -L "$OPENCLAW_PENDING_UPDATE_FILE" ]]; then
    die "Refusing to remove symlinked pending update metadata"
  fi
  rm -f -- "$OPENCLAW_PENDING_UPDATE_FILE"
}
