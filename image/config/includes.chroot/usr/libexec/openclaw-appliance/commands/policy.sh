# shellcheck shell=bash

OPENCLAW_POLICY_DIR="${OPENCLAW_POLICY_DIR:-/usr/share/openclaw-os/policies}"
OPENCLAW_POLICY_STATE_FILE="${OPENCLAW_POLICY_STATE_FILE:-/etc/openclaw/policy-state.json}"
OPENCLAW_POLICY_MAX_BYTES="${OPENCLAW_POLICY_MAX_BYTES:-1048576}"

policy_profile_path() {
  local profile="$1"
  [[ "$profile" =~ ^[a-z0-9][a-z0-9-]{0,63}$ ]] || die "Unsafe policy profile name: $profile"
  printf '%s/%s.json5\n' "$OPENCLAW_POLICY_DIR" "$profile"
}

policy_profile_exists() {
  local path
  path="$(policy_profile_path "$1")"
  [[ -f "$path" && ! -L "$path" ]]
}

policy_profile_risk() {
  case "$1" in
    locked) printf 'baseline\n' ;;
    connected) printf 'sandbox-network\n' ;;
    developer) printf 'writable-sandbox\n' ;;
    power-user) printf 'rootless-container-root\n' ;;
    host) printf 'host-execution\n' ;;
    custom) printf 'custom\n' ;;
    elevated) printf 'host-execution\n' ;;
    *) printf 'unknown\n' ;;
  esac
}

policy_requires_acknowledgement() {
  [[ "$1" != "locked" ]]
}

validate_policy_patch_file() {
  local patch_file="$1"
  [[ -f "$patch_file" && ! -L "$patch_file" ]] || \
    die "Policy patch must be a regular, non-symlinked file: $patch_file"

  local patch_size
  patch_size="$(stat -c '%s' "$patch_file" 2>/dev/null || true)"
  [[ "$patch_size" =~ ^[0-9]+$ ]] || die "Cannot inspect policy patch: $patch_file"
  ((patch_size > 0)) || die "Policy patch is empty: $patch_file"
  ((patch_size <= OPENCLAW_POLICY_MAX_BYTES)) || \
    die "Policy patch exceeds $OPENCLAW_POLICY_MAX_BYTES bytes"
}

policy_state_profile() {
  if [[ ! -e "$OPENCLAW_POLICY_STATE_FILE" ]]; then
    printf 'unmanaged\n'
    return 0
  fi
  [[ -f "$OPENCLAW_POLICY_STATE_FILE" && ! -L "$OPENCLAW_POLICY_STATE_FILE" ]] || {
    printf 'unsafe-state\n'
    return 0
  }
  jq -r '.profile // "unknown"' "$OPENCLAW_POLICY_STATE_FILE" 2>/dev/null || printf 'invalid-state\n'
}

record_policy_state() (
  set -Eeuo pipefail
  require_root
  local profile="$1"
  local source="$2"
  local source_hash="$3"

  [[ "$profile" =~ ^[a-z0-9][a-z0-9-]{0,63}$ ]] || die "Unsafe policy state profile"
  [[ "$source" =~ ^[a-z0-9][a-z0-9._:/+-]{0,255}$ ]] || die "Unsafe policy state source"
  [[ "$source_hash" =~ ^[a-f0-9]{64}$ ]] || die "Invalid policy source SHA-256"

  install -d -m 0755 "$(dirname "$OPENCLAW_POLICY_STATE_FILE")"
  local temporary
  temporary="$(mktemp "$(dirname "$OPENCLAW_POLICY_STATE_FILE")/.policy-state.XXXXXX")"
  trap 'rm -f "$temporary"' EXIT

  jq -n \
    --arg profile "$profile" \
    --arg risk "$(policy_profile_risk "$profile")" \
    --arg source "$source" \
    --arg sourceHash "$source_hash" \
    --arg appliedAt "$(date --utc +%Y-%m-%dT%H:%M:%SZ)" \
    '{
      schemaVersion: 1,
      profile: $profile,
      risk: $risk,
      source: $source,
      sourceHash: $sourceHash,
      appliedAt: $appliedAt
    }' >"$temporary"
  chmod 0600 "$temporary"
  mv -fT "$temporary" "$OPENCLAW_POLICY_STATE_FILE"
)

restore_policy_config() {
  local backup="$1"
  local gateway_was_active="$2"

  if [[ -f "$backup" && ! -L "$backup" ]]; then
    mv -fT "$backup" "$OPENCLAW_CONFIG_FILE"
  fi
  sandbox_reset || true
  if [[ "$gateway_was_active" == "yes" ]]; then
    systemctl restart openclaw.service || true
    wait_for_gateway_health 30 || warn "Gateway did not recover after restoring the prior policy"
  fi
}

apply_policy_patch_file() {
  require_root
  config_exists || die "OpenClaw is not configured"
  local patch_file="$1"
  local profile="$2"
  local source="$3"
  shift 3
  local -a replace_args=()
  local replace_path
  for replace_path in "$@"; do
    [[ "$replace_path" =~ ^[A-Za-z0-9_.\[\]\"-]+$ ]] || die "Unsafe replacement path"
    replace_args+=(--replace-path "$replace_path")
  done

  validate_policy_patch_file "$patch_file"
  run_openclaw config patch --file "$patch_file" "${replace_args[@]}" --dry-run

  local gateway_was_active=no
  if systemctl is-active --quiet openclaw.service; then
    gateway_was_active=yes
  fi

  local backup
  backup="$(mktemp "$(dirname "$OPENCLAW_CONFIG_FILE")/.policy-backup.XXXXXX")"
  cp --preserve=mode,ownership,timestamps "$OPENCLAW_CONFIG_FILE" "$backup"

  if [[ "$gateway_was_active" == "yes" ]]; then
    systemctl stop openclaw.service
  fi

  local policy_rc=0
  run_openclaw config patch --file "$patch_file" "${replace_args[@]}" || policy_rc=$?
  if ((policy_rc == 0)); then
    run_openclaw config validate || policy_rc=$?
  fi
  if ((policy_rc == 0)); then
    sandbox_reset || policy_rc=$?
  fi
  if ((policy_rc == 0)) && [[ "$gateway_was_active" == "yes" ]]; then
    systemctl restart openclaw.service || policy_rc=$?
    if ((policy_rc == 0)); then
      wait_for_gateway_health 45 || policy_rc=$?
    fi
  fi

  if ((policy_rc != 0)); then
    warn "Policy activation failed. Restoring the prior configuration."
    restore_policy_config "$backup" "$gateway_was_active"
    return "$policy_rc"
  fi

  local source_hash
  source_hash="$(sha256sum "$patch_file" | awk '{print $1}')"
  if ! record_policy_state "$profile" "$source" "$source_hash"; then
    warn "Policy state could not be recorded. Restoring the prior configuration."
    restore_policy_config "$backup" "$gateway_was_active"
    return 1
  fi

  rm -f -- "$backup"
  log "Applied OpenClaw execution policy: $profile"
}

policy_list() {
  local path found=no
  while IFS= read -r path; do
    [[ -f "$path" && ! -L "$path" ]] || continue
    found=yes
    local profile
    profile="$(basename "$path" .json5)"
    printf '%-12s %s\n' "$profile" "$(policy_profile_risk "$profile")"
  done < <(find "$OPENCLAW_POLICY_DIR" -maxdepth 1 -type f -name '*.json5' -print 2>/dev/null | sort)
  [[ "$found" == "yes" ]] || die "No OpenClaw OS policy profiles are installed"
}

policy_status_json() {
  local profile
  profile="$(policy_state_profile)"
  jq -n \
    --arg profile "$profile" \
    --arg risk "$(policy_profile_risk "$profile")" \
    --arg sandboxMode "$(oc_get agents.defaults.sandbox.mode unknown)" \
    --arg sandboxBackend "$(oc_get agents.defaults.sandbox.backend unknown)" \
    --arg sandboxNetwork "$(oc_get agents.defaults.sandbox.docker.network not-applicable)" \
    --arg readOnlyRoot "$(oc_get agents.defaults.sandbox.docker.readOnlyRoot not-applicable)" \
    --arg containerUser "$(oc_get agents.defaults.sandbox.docker.user default)" \
    --arg elevatedEnabled "$(oc_get tools.elevated.enabled false)" \
    '{
      profile: $profile,
      risk: $risk,
      effective: {
        sandboxMode: $sandboxMode,
        sandboxBackend: $sandboxBackend,
        sandboxNetwork: $sandboxNetwork,
        readOnlyRoot: $readOnlyRoot,
        containerUser: $containerUser,
        elevatedEnabled: $elevatedEnabled
      }
    }'
}

policy_status() {
  if [[ "${1:-}" == "--json" ]]; then
    policy_status_json
    return 0
  fi
  local profile
  profile="$(policy_state_profile)"
  cat <<STATUS
Managed profile:    $profile
Risk class:         $(policy_profile_risk "$profile")
Sandbox mode:       $(oc_get agents.defaults.sandbox.mode unknown)
Sandbox backend:    $(oc_get agents.defaults.sandbox.backend unknown)
Sandbox network:    $(oc_get agents.defaults.sandbox.docker.network not-applicable)
Read-only root:     $(oc_get agents.defaults.sandbox.docker.readOnlyRoot not-applicable)
Container user:     $(oc_get agents.defaults.sandbox.docker.user default)
Elevated enabled:   $(oc_get tools.elevated.enabled false)
STATUS
}

require_policy_acknowledgement() {
  local profile="$1"
  local acknowledged="$2"
  if policy_requires_acknowledgement "$profile" && [[ "$acknowledged" != "yes" ]]; then
    die "The $profile profile weakens isolation. Re-run with --acknowledge-risk after reviewing docs/POLICIES.md."
  fi
}

parse_acknowledgement() {
  local acknowledged=no
  local argument
  for argument in "$@"; do
    case "$argument" in
      --acknowledge-risk) acknowledged=yes ;;
      *) die "Unknown policy option: $argument" ;;
    esac
  done
  printf '%s\n' "$acknowledged"
}

validate_elevated_provider() {
  local provider="$1"
  [[ "$provider" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]] || \
    die "Elevated provider must contain only letters, numbers, dot, underscore, and hyphen"
  case "${provider,,}" in
    __proto__|prototype|constructor) die "Reserved elevated provider name" ;;
  esac
}

validate_elevated_sender() {
  local sender="$1"
  [[ -n "$sender" && ${#sender} -le 256 ]] || die "Elevated sender identity must be 1 to 256 characters"
  local LC_ALL=C
  [[ "$sender" =~ ^[[:graph:]][[:print:]]*$ ]] || \
    die "Elevated sender identity must be printable and single-line"
}

policy_elevated_enable() (
  set -Eeuo pipefail
  require_root
  local provider="$1"
  local sender="$2"
  shift 2
  local acknowledged
  acknowledged="$(parse_acknowledgement "$@")"
  require_policy_acknowledgement elevated "$acknowledged"
  validate_elevated_provider "$provider"
  validate_elevated_sender "$sender"
  ensure_runtime_directory

  local patch profile
  patch="$(mktemp /run/openclaw/elevated-policy.XXXXXX)"
  trap 'rm -f "$patch"' EXIT
  jq -n \
    --arg provider "$provider" \
    --arg sender "$sender" \
    '{tools: {elevated: {enabled: true, allowFrom: {($provider): [$sender]}}}}' >"$patch"
  chmod 0600 "$patch"
  profile="$(policy_state_profile)"
  [[ "$profile" =~ ^[a-z0-9][a-z0-9-]{0,63}$ ]] || profile=custom
  apply_policy_patch_file "$patch" "$profile" "generated:elevated-enabled" tools.elevated
)

policy_elevated_disable() (
  set -Eeuo pipefail
  require_root
  ensure_runtime_directory
  local patch profile
  patch="$(mktemp /run/openclaw/elevated-policy.XXXXXX)"
  trap 'rm -f "$patch"' EXIT
  printf '%s\n' '{tools: {elevated: {enabled: false, allowFrom: {}}}}' >"$patch"
  chmod 0600 "$patch"
  profile="$(policy_state_profile)"
  [[ "$profile" =~ ^[a-z0-9][a-z0-9-]{0,63}$ ]] || profile=custom
  apply_policy_patch_file "$patch" "$profile" "generated:elevated-disabled" tools.elevated
)

command_policy() {
  local action="${1:-status}"
  shift || true
  case "$action" in
    list)
      (($# == 0)) || die "policy list does not accept arguments"
      policy_list
      ;;
    status)
      (($# <= 1)) || die "policy status accepts only --json"
      policy_status "${1:-}"
      ;;
    apply)
      local profile="${1:-}"
      [[ -n "$profile" ]] || die "Usage: openclaw-appliance policy apply <profile> [--acknowledge-risk]"
      shift
      local acknowledged
      acknowledged="$(parse_acknowledgement "$@")"
      policy_profile_exists "$profile" || die "Unknown or unsafe policy profile: $profile"
      require_policy_acknowledgement "$profile" "$acknowledged"
      apply_policy_patch_file "$(policy_profile_path "$profile")" "$profile" "profile:$profile"
      ;;
    patch)
      local patch_file="${1:-}"
      [[ -n "$patch_file" ]] || die "Usage: openclaw-appliance policy patch <file> --acknowledge-risk"
      shift
      local acknowledged
      acknowledged="$(parse_acknowledgement "$@")"
      require_policy_acknowledgement custom "$acknowledged"
      apply_policy_patch_file "$patch_file" custom "custom:file"
      ;;
    elevated)
      local elevated_action="${1:-status}"
      shift || true
      case "$elevated_action" in
        status) (($# == 0)) || die "policy elevated status does not accept arguments"; policy_status ;;
        enable)
          (($# >= 2)) || die "Usage: openclaw-appliance policy elevated enable <provider> <sender> --acknowledge-risk"
          local provider="$1" sender="$2"
          shift 2
          policy_elevated_enable "$provider" "$sender" "$@"
          ;;
        disable)
          (($# == 0)) || die "policy elevated disable does not accept arguments"
          policy_elevated_disable
          ;;
        *) die "Unknown elevated policy action: $elevated_action" ;;
      esac
      ;;
    *) die "Unknown policy action: $action" ;;
  esac
}
