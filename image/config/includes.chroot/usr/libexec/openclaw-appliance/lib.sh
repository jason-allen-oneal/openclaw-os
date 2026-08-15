#!/usr/bin/env bash

APPLIANCE_ENV_FILE="${APPLIANCE_ENV_FILE:-/etc/openclaw/appliance.env}"
APPLIANCE_CONFIG_FILE="${APPLIANCE_CONFIG_FILE:-/etc/openclaw/appliance.conf}"
RELEASE_ENV_FILE="${RELEASE_ENV_FILE:-/usr/share/openclaw-os/release.env}"
OPENCLAW_USER="${OPENCLAW_USER:-openclaw}"
OPENCLAW_GROUP="${OPENCLAW_GROUP:-openclaw}"
OPENCLAW_CONFIG_FILE="${OPENCLAW_CONFIG_FILE:-/var/lib/openclaw/state/openclaw.json}"
OPENCLAW_RELEASES_DIR="${OPENCLAW_RELEASES_DIR:-/opt/openclaw/releases}"
OPENCLAW_CURRENT_LINK="${OPENCLAW_CURRENT_LINK:-/opt/openclaw/current}"
NODE_CURRENT_LINK="${NODE_CURRENT_LINK:-/opt/node/current}"

log() {
  printf '[openclaw-os] %s\n' "$*"
}

warn() {
  printf '[openclaw-os] WARNING: %s\n' "$*" >&2
}

die() {
  printf '[openclaw-os] ERROR: %s\n' "$*" >&2
  exit 1
}

require_root() {
  [[ "$(id -u)" -eq 0 ]] || die "This command requires root. Use sudo."
}

load_release_env() {
  [[ -r "$RELEASE_ENV_FILE" ]] || die "Missing release metadata: $RELEASE_ENV_FILE"
  # shellcheck disable=SC1090
  source "$RELEASE_ENV_FILE"
}

load_appliance_config() {
  BACKUP_RETENTION_DAYS=30
  BACKUP_INCLUDE_WORKSPACE=yes
  UPDATE_CHANNEL=extended-stable
  HEALTH_TIMEOUT_MS=15000
  KEEP_OPENCLAW_RELEASES=3
  if [[ -r "$APPLIANCE_CONFIG_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$APPLIANCE_CONFIG_FILE"
  fi
}

openclaw_env_args() {
  printf '%s\0' \
    "HOME=/var/lib/openclaw" \
    "OPENCLAW_HOME=/var/lib/openclaw" \
    "OPENCLAW_STATE_DIR=/var/lib/openclaw/state" \
    "OPENCLAW_CONFIG_PATH=$OPENCLAW_CONFIG_FILE" \
    "OPENCLAW_SERVICE_REPAIR_POLICY=external" \
    "OPENCLAW_SYSTEMD_UNIT=openclaw.service" \
    "XDG_CONFIG_HOME=/var/lib/openclaw/.config" \
    "XDG_DATA_HOME=/var/lib/openclaw/.local/share" \
    "XDG_RUNTIME_DIR=/run/openclaw" \
    "CONTAINER_HOST=unix:///run/openclaw/podman.sock" \
    "DOCKER_HOST=unix:///run/openclaw/podman.sock" \
    "PATH=/opt/openclaw/current/bin:/opt/node/current/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
    "TERM=${TERM:-xterm}" \
    "LANG=${LANG:-C.UTF-8}"
}

run_openclaw_bin() {
  local binary="$1"
  shift
  [[ -x "$binary" ]] || die "OpenClaw executable not found: $binary"

  local -a env_args=()
  while IFS= read -r -d '' item; do
    env_args+=("$item")
  done < <(openclaw_env_args)

  if [[ "$(id -u)" -eq 0 ]]; then
    runuser -u "$OPENCLAW_USER" -- env "${env_args[@]}" "$binary" "$@"
  elif [[ "$(id -un)" == "$OPENCLAW_USER" ]]; then
    env "${env_args[@]}" "$binary" "$@"
  else
    die "Run this command as root or $OPENCLAW_USER."
  fi
}

run_openclaw() {
  run_openclaw_bin "$OPENCLAW_CURRENT_LINK/bin/openclaw" "$@"
}

run_podman_local() {
  local -a env_args=(
    "HOME=/var/lib/openclaw"
    "XDG_CONFIG_HOME=/var/lib/openclaw/.config"
    "XDG_DATA_HOME=/var/lib/openclaw/.local/share"
    "XDG_RUNTIME_DIR=/run/openclaw"
    "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
  )
  if [[ "$(id -u)" -eq 0 ]]; then
    runuser -u "$OPENCLAW_USER" -- env "${env_args[@]}" /usr/bin/podman "$@"
  elif [[ "$(id -un)" == "$OPENCLAW_USER" ]]; then
    env "${env_args[@]}" /usr/bin/podman "$@"
  else
    die "Run this command as root or $OPENCLAW_USER."
  fi
}

config_exists() {
  [[ -f "$OPENCLAW_CONFIG_FILE" && ! -L "$OPENCLAW_CONFIG_FILE" ]]
}

current_openclaw_version() {
  if [[ ! -x "$OPENCLAW_CURRENT_LINK/bin/openclaw" ]]; then
    printf 'not-installed\n'
    return 0
  fi
  PATH="$NODE_CURRENT_LINK/bin:/usr/bin:/bin" \
    "$OPENCLAW_CURRENT_LINK/bin/openclaw" --version 2>/dev/null | head -n 1
}

download_https() {
  local url="$1"
  local destination="$2"
  [[ "$url" == https://* ]] || die "Refusing non-HTTPS download: $url"
  curl --proto '=https' --tlsv1.2 --fail --location --silent --show-error \
    --retry 4 --retry-all-errors \
    --header 'User-Agent: openclaw-os-appliance' \
    "$url" -o "$destination"
}

verify_sri() {
  local file="$1"
  local expected="$2"
  local algorithm="${expected%%-*}"
  local expected_digest="${expected#*-}"
  local actual_digest

  case "$algorithm" in
    sha512)
      actual_digest="$(openssl dgst -sha512 -binary "$file" | openssl base64 -A)"
      ;;
    sha256)
      actual_digest="$(openssl dgst -sha256 -binary "$file" | openssl base64 -A)"
      ;;
    *)
      die "Unsupported SRI algorithm: $algorithm"
      ;;
  esac

  [[ "$actual_digest" == "$expected_digest" ]] || die "Artifact integrity verification failed for $file"
}

extract_release_integrity() {
  grep -i 'npm integrity:' | grep -oE 'sha512-[A-Za-z0-9+/=]+' | head -n 1
}

extract_release_commit() {
  grep -i 'Release commit:' | grep -oE '[a-f0-9]{40}' | head -n 1
}

verify_openclaw_release_metadata() (
  set -Eeuo pipefail
  local version="$1"
  local integrity="$2"
  local expected_commit="${3:-}"
  [[ "$version" =~ ^[0-9A-Za-z._+-]+$ ]] || die "Unsafe OpenClaw version string: $version"
  [[ "$integrity" =~ ^sha512-[A-Za-z0-9+/=]+$ ]] || die "Invalid OpenClaw integrity value"
  [[ -z "$expected_commit" || "$expected_commit" =~ ^[a-f0-9]{40}$ ]] || \
    die "Invalid expected OpenClaw release commit"

  local work_dir metadata body release_integrity release_commit
  work_dir="$(mktemp -d /tmp/openclaw-release-metadata.XXXXXX)"
  trap 'rm -rf "$work_dir"' EXIT
  metadata="$work_dir/release.json"

  download_https \
    "https://api.github.com/repos/openclaw/openclaw/releases/tags/v${version}" \
    "$metadata"

  jq -e \
    --arg tag "v$version" \
    '.tag_name == $tag and .draft == false and (.published_at | type == "string")' \
    "$metadata" >/dev/null || die "GitHub release metadata did not validate for OpenClaw $version"

  body="$(jq -r '.body // ""' "$metadata")"
  release_integrity="$(extract_release_integrity <<<"$body" || true)"
  [[ -n "$release_integrity" ]] || die "OpenClaw release $version does not publish npm integrity"
  [[ "$release_integrity" == "$integrity" ]] || \
    die "OpenClaw registry integrity does not match the GitHub release record"

  if [[ -n "$expected_commit" ]]; then
    release_commit="$(extract_release_commit <<<"$body" || true)"
    [[ "$release_commit" == "$expected_commit" ]] || \
      die "OpenClaw release commit does not match the pinned build metadata"
  fi
)

parse_npm_metadata() {
  local metadata="$1"
  RESOLVED_VERSION="$(jq -r '.version // empty' <<<"$metadata")"
  RESOLVED_INTEGRITY="$(jq -r '.dist.integrity // empty' <<<"$metadata")"
  RESOLVED_TARBALL="$(jq -r '.dist.tarball // empty' <<<"$metadata")"
  RESOLVED_SIGNATURE_COUNT="$(jq -r 'if (.dist.signatures | type) == "array" then (.dist.signatures | length) else 0 end' <<<"$metadata")"

  [[ "$RESOLVED_VERSION" =~ ^[0-9A-Za-z._+-]+$ ]] || die "npm returned an invalid version"
  [[ "$RESOLVED_INTEGRITY" =~ ^sha512-[A-Za-z0-9+/=]+$ ]] || \
    die "npm did not return a valid SHA-512 SRI"
  [[ "$RESOLVED_TARBALL" == "https://registry.npmjs.org/openclaw/-/openclaw-${RESOLVED_VERSION}.tgz" ]] || \
    die "npm returned an unexpected OpenClaw tarball URL"
  [[ "$RESOLVED_SIGNATURE_COUNT" =~ ^[0-9]+$ ]] || die "npm returned invalid signature metadata"
  ((RESOLVED_SIGNATURE_COUNT > 0)) || die "npm did not publish package signatures for OpenClaw $RESOLVED_VERSION"
}

resolve_npm_metadata() {
  local spec="$1"
  [[ "$spec" =~ ^[0-9A-Za-z._+-]+$ ]] || die "Unsafe npm version or tag: $spec"

  local work_dir metadata_file metadata
  work_dir="$(mktemp -d /tmp/openclaw-registry-metadata.XXXXXX)"
  metadata_file="$work_dir/metadata.json"

  download_https "https://registry.npmjs.org/openclaw/${spec}" "$metadata_file"
  metadata="$(cat "$metadata_file")"
  parse_npm_metadata "$metadata"
  verify_openclaw_release_metadata "$RESOLVED_VERSION" "$RESOLVED_INTEGRITY"
  rm -rf "$work_dir"
}

install_openclaw_release() (
  set -Eeuo pipefail
  require_root
  local version="$1"
  local integrity="$2"
  local tarball_url="$3"
  local expected_commit="${4:-}"

  [[ "$version" =~ ^[0-9A-Za-z._+-]+$ ]] || die "Unsafe OpenClaw version string: $version"
  [[ "$tarball_url" == "https://registry.npmjs.org/openclaw/-/openclaw-${version}.tgz" ]] || \
    die "Unexpected OpenClaw tarball URL"
  [[ -x "$NODE_CURRENT_LINK/bin/npm" ]] || die "Node.js runtime is not installed"
  verify_openclaw_release_metadata "$version" "$integrity" "$expected_commit"

  local target="$OPENCLAW_RELEASES_DIR/$version"
  if [[ -x "$target/bin/openclaw" ]]; then
    log "OpenClaw $version is already installed"
    [[ -e "$OPENCLAW_CURRENT_LINK" ]] || ln -sfnT "$target" "$OPENCLAW_CURRENT_LINK"
    return 0
  fi
  [[ ! -e "$target" ]] || die "OpenClaw release target exists but is incomplete: $target"

  install -d -m 0755 "$OPENCLAW_RELEASES_DIR"
  local work_dir archive staging npm_home npm_cache npm_user_config npm_global_config
  work_dir="$(mktemp -d /tmp/openclaw-install.XXXXXX)"
  archive="$work_dir/openclaw.tgz"
  staging="$OPENCLAW_RELEASES_DIR/.${version}.staging.$$"
  npm_home="$work_dir/home"
  npm_cache="$work_dir/cache"
  npm_user_config="$work_dir/npmrc"
  npm_global_config="$work_dir/global-npmrc"
  trap 'rm -rf "$work_dir" "$staging"' EXIT
  rm -rf "$staging"
  install -d -m 0700 "$npm_home" "$npm_cache"
  : >"$npm_user_config"
  : >"$npm_global_config"

  log "Downloading OpenClaw $version"
  download_https "$tarball_url" "$archive"
  verify_sri "$archive" "$integrity"

  install -d -m 0755 "$staging"
  log "Installing OpenClaw $version into a staged prefix"
  PATH="$NODE_CURRENT_LINK/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
  HOME="$npm_home" \
  npm_config_userconfig="$npm_user_config" \
  npm_config_globalconfig="$npm_global_config" \
  npm_config_cache="$npm_cache" \
  npm_config_registry=https://registry.npmjs.org/ \
  npm_config_audit=false \
  npm_config_fund=false \
  npm_config_update_notifier=false \
    "$NODE_CURRENT_LINK/bin/npm" install \
      --global \
      --prefix "$staging" \
      --omit=dev \
      --no-audit \
      --no-fund \
      "$archive"

  [[ -x "$staging/bin/openclaw" ]] || die "Staged OpenClaw binary is missing"
  local reported
  reported="$(PATH="$NODE_CURRENT_LINK/bin:/usr/bin:/bin" "$staging/bin/openclaw" --version 2>/dev/null | head -n 1)"
  [[ "$reported" == *"$version"* ]] || die "Staged version mismatch: $reported"

  chown -R root:root "$staging"
  chmod -R go-w "$staging"
  mv "$staging" "$target"
  [[ -e "$OPENCLAW_CURRENT_LINK" ]] || ln -sfnT "$target" "$OPENCLAW_CURRENT_LINK"
  log "Installed OpenClaw $version"
)

wait_for_gateway_health() {
  load_appliance_config
  local attempts="${1:-30}"
  local timeout_ms="${HEALTH_TIMEOUT_MS:-15000}"
  local output
  local i
  for ((i = 1; i <= attempts; i++)); do
    if output="$(run_openclaw health --json --timeout "$timeout_ms" 2>/dev/null)" \
      && jq -e '.ok == true' >/dev/null 2>&1 <<<"$output"; then
      return 0
    fi
    sleep 1
  done
  return 1
}
