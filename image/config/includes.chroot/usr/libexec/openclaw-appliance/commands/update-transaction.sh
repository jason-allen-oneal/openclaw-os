# shellcheck shell=bash

prune_releases() {
  load_update_config
  [[ "$KEEP_OPENCLAW_RELEASES" =~ ^[0-9]+$ ]] || return 0
  ((KEEP_OPENCLAW_RELEASES >= 1)) || return 0

  local active pending_target=""
  active="$(active_release_target)"
  if pending_update_exists; then
    load_pending_update
    pending_target="$OPENCLAW_RELEASES_DIR/$PENDING_VERSION"
  fi

  local kept=0 path
  while IFS= read -r path; do
    [[ -d "$path" ]] || continue
    if [[ "$path" == "$active" || "$path" == "$pending_target" ]]; then
      continue
    fi
    if ((kept < KEEP_OPENCLAW_RELEASES - 1)); then
      kept=$((kept + 1))
      continue
    fi
    rm -rf --one-file-system "$path"
  done < <(find "$OPENCLAW_RELEASES_DIR" -mindepth 1 -maxdepth 1 -type d ! -name '.*' -printf '%T@ %p\n' 2>/dev/null | sort -nr | cut -d' ' -f2-)
}

restore_previous_release() {
  local previous="$1"
  local gateway_was_active="$2"

  systemctl stop openclaw.service >/dev/null 2>&1 || true
  if [[ -n "$previous" && -d "$previous" ]]; then
    ln -sfnT "$previous" "$OPENCLAW_CURRENT_LINK"
  else
    rm -f -- "$OPENCLAW_CURRENT_LINK"
  fi

  if [[ "$gateway_was_active" == "yes" && -n "$previous" && -d "$previous" ]]; then
    systemctl restart openclaw.service || true
    wait_for_gateway_health 30 || warn "Previous Gateway failed its health check after restoration"
  fi
}

activate_release() {
  local target="$1"
  local previous="$2"
  local gateway_was_active="${3:-yes}"

  [[ "$gateway_was_active" == "yes" || "$gateway_was_active" == "no" ]] || \
    die "Gateway activity state must be yes or no"
  [[ "$target" == "$OPENCLAW_RELEASES_DIR/"* ]] || \
    die "Candidate OpenClaw release is outside $OPENCLAW_RELEASES_DIR"
  [[ -d "$target" && ! -L "$target" && -x "$target/bin/openclaw" ]] || \
    die "Candidate OpenClaw release is missing or unsafe"
  if [[ -e "$OPENCLAW_CURRENT_LINK" && ! -L "$OPENCLAW_CURRENT_LINK" ]]; then
    die "Active OpenClaw path is not a symbolic link"
  fi

  ln -sfnT "$target" "$OPENCLAW_CURRENT_LINK"

  if ! config_exists; then
    log "Activated $(basename "$target"); Gateway remains disabled until setup"
    return 0
  fi

  if ! run_openclaw config validate; then
    warn "Candidate config validation failed. Restoring the previous release."
    restore_previous_release "$previous" "$gateway_was_active"
    return 1
  fi

  if [[ "$gateway_was_active" == "no" ]]; then
    log "Activated $(basename "$target"); Gateway remains stopped"
    return 0
  fi

  if systemctl restart openclaw.service && wait_for_gateway_health 45; then
    return 0
  fi

  warn "Candidate Gateway failed its health check. Rolling back code."
  restore_previous_release "$previous" yes
  return 1
}

acquire_release_lock() {
  require_root
  ensure_runtime_directory
  exec 8>"$OPENCLAW_RELEASE_LOCK_FILE"
  flock -n 8 || die "Another OpenClaw release transaction is already running"
}

parse_update_arguments() {
  UPDATE_ACTION=apply
  UPDATE_SPEC=""
  UPDATE_ALLOW_UNTESTED=no

  if (($# > 0)); then
    case "$1" in
      check|stage|apply|status|cancel)
        UPDATE_ACTION="$1"
        shift
        ;;
    esac
  fi

  local argument
  for argument in "$@"; do
    case "$argument" in
      --allow-untested)
        UPDATE_ALLOW_UNTESTED=yes
        ;;
      --)
        ;;
      -*)
        die "Unknown update option: $argument"
        ;;
      *)
        [[ -z "$UPDATE_SPEC" ]] || die "Only one OpenClaw version or npm tag may be supplied"
        UPDATE_SPEC="$argument"
        ;;
    esac
  done

  if [[ "$UPDATE_ACTION" == "status" || "$UPDATE_ACTION" == "cancel" ]]; then
    [[ -z "$UPDATE_SPEC" ]] || die "update $UPDATE_ACTION does not accept a version or npm tag"
    [[ "$UPDATE_ALLOW_UNTESTED" == "no" ]] || die "update $UPDATE_ACTION does not accept --allow-untested"
  fi
}

resolve_update_candidate() {
  local spec="$1"
  [[ -x "$NODE_CURRENT_LINK/bin/npm" ]] || die "Node.js runtime is missing"
  resolve_npm_metadata "$spec"
  RESOLVED_COMPATIBILITY="$(openclaw_version_compatibility "$RESOLVED_VERSION")"
}

print_update_check() {
  local spec="$1"
  local current_target current_version activation
  current_target="$(active_release_target)"
  if [[ -n "$current_target" ]]; then
    current_version="$(basename "$current_target")"
  else
    current_version="not-installed"
  fi
  activation="allowed"

  if [[ "$RESOLVED_COMPATIBILITY" == "untested" ]]; then
    if [[ "$spec" != "$RESOLVED_VERSION" ]]; then
      activation="blocked: request the exact version before staging"
    elif [[ "$UPDATE_ALLOW_UNTESTED" == "yes" || "$OPENCLAW_UPDATE_POLICY" == "allow-untested-exact" ]]; then
      activation="allowed by explicit untested-release policy"
    else
      activation="blocked: exact version requires --allow-untested"
    fi
  fi

  cat <<CHECK
Requested:       $spec
Resolved:        $RESOLVED_VERSION
Active:          $current_version
Compatibility:   $RESOLVED_COMPATIBILITY
Update policy:   $OPENCLAW_UPDATE_POLICY
Activation:      $activation
CHECK
}

stage_resolved_update() {
  local requested_spec="$1"
  local allow_untested="$2"
  local current_target current_version target

  require_resolved_update_authorization \
    "$RESOLVED_VERSION" \
    "$requested_spec" \
    "$allow_untested" \
    "$RESOLVED_COMPATIBILITY"

  current_target="$(active_release_target)"
  current_version="$(basename "$current_target" 2>/dev/null || true)"
  target="$OPENCLAW_RELEASES_DIR/$RESOLVED_VERSION"

  if [[ "$current_version" == "$RESOLVED_VERSION" ]]; then
    log "OpenClaw $RESOLVED_VERSION is already active"
    if pending_update_exists; then
      load_pending_update
      [[ "$PENDING_VERSION" != "$RESOLVED_VERSION" ]] || clear_pending_update
    fi
    return 0
  fi

  install_openclaw_release "$RESOLVED_VERSION" "$RESOLVED_INTEGRITY" "$RESOLVED_TARBALL"
  if [[ -z "$current_target" && -L "$OPENCLAW_CURRENT_LINK" ]]; then
    local installed_link
    installed_link="$(readlink -f "$OPENCLAW_CURRENT_LINK" 2>/dev/null || true)"
    if [[ "$installed_link" == "$target" ]]; then
      rm -f -- "$OPENCLAW_CURRENT_LINK"
    fi
  fi
  if config_exists; then
    run_openclaw_bin "$target/bin/openclaw" config validate
  fi

  write_pending_update \
    "$RESOLVED_VERSION" \
    "$RESOLVED_INTEGRITY" \
    "$RESOLVED_TARBALL" \
    "$requested_spec" \
    "$RESOLVED_COMPATIBILITY"
  log "Staged OpenClaw $RESOLVED_VERSION. The active release was not changed."
}

use_pending_candidate() {
  local requested_spec="$1"
  pending_update_exists || return 1
  load_pending_update
  if [[ -n "$requested_spec" && "$requested_spec" != "$PENDING_VERSION" ]]; then
    return 1
  fi

  RESOLVED_VERSION="$PENDING_VERSION"
  RESOLVED_INTEGRITY="$PENDING_INTEGRITY"
  RESOLVED_TARBALL="$PENDING_TARBALL"
  RESOLVED_COMPATIBILITY="$(openclaw_version_compatibility "$PENDING_VERSION")"
  RESOLVED_REQUESTED_SPEC="$PENDING_VERSION"
  return 0
}
