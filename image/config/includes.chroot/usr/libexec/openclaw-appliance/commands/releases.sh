# shellcheck shell=bash

OPENCLAW_RELEASES_MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$OPENCLAW_RELEASES_MODULE_DIR/update-policy.sh"
# shellcheck disable=SC1091
source "$OPENCLAW_RELEASES_MODULE_DIR/update-transaction.sh"

command_update_check() {
  load_update_config
  local spec="${1:-$UPDATE_CHANNEL}"
  resolve_update_candidate "$spec"
  print_update_check "$spec"
}

command_update_stage() {
  require_root
  acquire_release_lock
  load_update_config
  local spec="${1:-$UPDATE_CHANNEL}"
  resolve_update_candidate "$spec"
  stage_resolved_update "$spec" "$UPDATE_ALLOW_UNTESTED"
}

command_update_apply() {
  require_root
  acquire_release_lock
  load_update_config

  local spec="${1:-}"
  local requested_spec
  if use_pending_candidate "$spec"; then
    requested_spec="$RESOLVED_REQUESTED_SPEC"
    log "Using staged OpenClaw $RESOLVED_VERSION"
  else
    [[ -n "$spec" ]] || spec="$UPDATE_CHANNEL"
    resolve_update_candidate "$spec"
    requested_spec="$spec"
    stage_resolved_update "$requested_spec" "$UPDATE_ALLOW_UNTESTED"
  fi

  require_resolved_update_authorization \
    "$RESOLVED_VERSION" \
    "$requested_spec" \
    "$UPDATE_ALLOW_UNTESTED" \
    "$RESOLVED_COMPATIBILITY"

  local target current_target current_version gateway_was_active=no
  target="$OPENCLAW_RELEASES_DIR/$RESOLVED_VERSION"
  current_target="$(active_release_target)"
  current_version="$(basename "$current_target" 2>/dev/null || true)"

  if [[ "$current_version" == "$RESOLVED_VERSION" ]]; then
    log "OpenClaw $RESOLVED_VERSION is already active"
    if pending_update_exists; then
      load_pending_update
      [[ "$PENDING_VERSION" != "$RESOLVED_VERSION" ]] || clear_pending_update
    fi
    return 0
  fi

  [[ -d "$target" && ! -L "$target" && -x "$target/bin/openclaw" ]] || \
    die "Staged OpenClaw release is incomplete or unsafe: $target"
  if config_exists; then
    run_openclaw_bin "$target/bin/openclaw" config validate
    command_backup
  fi

  if systemctl is-active --quiet openclaw.service; then
    gateway_was_active=yes
    systemctl stop openclaw.service
  fi

  if ! activate_release "$target" "$current_target" "$gateway_was_active"; then
    die "OpenClaw update failed and code was rolled back"
  fi

  if pending_update_exists; then
    load_pending_update
    [[ "$PENDING_VERSION" != "$RESOLVED_VERSION" ]] || clear_pending_update
  fi
  prune_releases
  log "OpenClaw $RESOLVED_VERSION is active"
}

command_update_status() {
  load_update_config
  validate_compatibility_manifest
  local active
  active="$(active_release_target)"
  local active_version="not-installed"
  [[ -z "$active" ]] || active_version="$(basename "$active")"
  cat <<STATUS
Active release:  $active_version
Update channel:  $UPDATE_CHANNEL
Update policy:   $OPENCLAW_UPDATE_POLICY
Tested versions: $(jq -r '.testedOpenclawVersions | join(", ")' "$OPENCLAW_COMPATIBILITY_FILE")
STATUS
  if pending_update_exists; then
    load_pending_update
    cat <<PENDING
Staged release:  $PENDING_VERSION
Compatibility:   $PENDING_COMPATIBILITY
Staged at:        $PENDING_STAGED_AT
PENDING
  else
    printf 'Staged release:  none\n'
  fi
}

command_update_cancel() {
  require_root
  acquire_release_lock
  if pending_update_exists; then
    load_pending_update
    clear_pending_update
    log "Cancelled staged OpenClaw $PENDING_VERSION activation"
  else
    log "No staged OpenClaw update exists"
  fi
}

command_update() {
  parse_update_arguments "$@"
  case "$UPDATE_ACTION" in
    check) command_update_check "$UPDATE_SPEC" ;;
    stage) command_update_stage "$UPDATE_SPEC" ;;
    apply) command_update_apply "$UPDATE_SPEC" ;;
    status) command_update_status ;;
    cancel) command_update_cancel ;;
  esac
}

command_releases() {
  local plain="${1:-}"
  local active pending_target=""
  active="$(active_release_target)"
  if pending_update_exists; then
    load_pending_update
    pending_target="$OPENCLAW_RELEASES_DIR/$PENDING_VERSION"
  fi

  local path suffix
  while IFS= read -r path; do
    [[ -d "$path" ]] || continue
    if [[ "$plain" == "--plain" ]]; then
      basename "$path"
      continue
    fi
    suffix=""
    [[ "$path" == "$active" ]] && suffix="${suffix} active"
    [[ "$path" == "$pending_target" ]] && suffix="${suffix} staged"
    if [[ -n "$suffix" ]]; then
      printf '* %s (%s)\n' "$(basename "$path")" "${suffix# }"
    else
      printf '  %s\n' "$(basename "$path")"
    fi
  done < <(find "$OPENCLAW_RELEASES_DIR" -mindepth 1 -maxdepth 1 -type d ! -name '.*' -printf '%T@ %p\n' 2>/dev/null | sort -nr | cut -d' ' -f2-)
}

command_rollback() {
  require_root
  acquire_release_lock
  local requested="${1:-}"
  local active target gateway_was_active=no
  active="$(active_release_target)"

  if [[ -z "$requested" ]]; then
    local candidate
    target=""
    while IFS= read -r candidate; do
      [[ -d "$candidate" ]] || continue
      if [[ "$candidate" != "$active" ]]; then
        target="$candidate"
        break
      fi
    done < <(find "$OPENCLAW_RELEASES_DIR" -mindepth 1 -maxdepth 1 -type d ! -name '.*' -printf '%T@ %p\n' 2>/dev/null | sort -nr | cut -d' ' -f2-)
  else
    [[ "$requested" =~ ^[0-9A-Za-z._+-]+$ ]] || die "Unsafe release name"
    target="$OPENCLAW_RELEASES_DIR/$requested"
  fi

  [[ -n "$target" && -d "$target" && ! -L "$target" && -x "$target/bin/openclaw" ]] || \
    die "Requested rollback release is not installed or is unsafe"
  [[ -n "$active" && -d "$active" ]] || die "Active OpenClaw release cannot be resolved"
  [[ "$target" != "$active" ]] || {
    log "$(basename "$target") is already active"
    return 0
  }

  if config_exists; then
    run_openclaw_bin "$target/bin/openclaw" config validate
  fi
  if systemctl is-active --quiet openclaw.service; then
    gateway_was_active=yes
    systemctl stop openclaw.service
  fi
  if ! activate_release "$target" "$active" "$gateway_was_active"; then
    die "Rollback target failed and the previous release was restored"
  fi
  log "Rolled back to $(basename "$target")"
}
