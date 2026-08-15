# shellcheck shell=bash

prune_releases() {
  load_appliance_config
  [[ "$KEEP_OPENCLAW_RELEASES" =~ ^[0-9]+$ ]] || return 0
  ((KEEP_OPENCLAW_RELEASES >= 1)) || return 0

  local active
  active="$(readlink -f "$OPENCLAW_CURRENT_LINK" 2>/dev/null || true)"
  local kept=0 path
  while IFS= read -r path; do
    [[ -d "$path" ]] || continue
    if [[ "$path" == "$active" ]]; then
      continue
    fi
    if ((kept < KEEP_OPENCLAW_RELEASES - 1)); then
      kept=$((kept + 1))
      continue
    fi
    rm -rf --one-file-system "$path"
  done < <(find "$OPENCLAW_RELEASES_DIR" -mindepth 1 -maxdepth 1 -type d ! -name '.*' -printf '%T@ %p\n' | sort -nr | cut -d' ' -f2-)
}

activate_release() {
  local target="$1"
  local previous="$2"
  ln -sfnT "$target" "$OPENCLAW_CURRENT_LINK"

  if ! config_exists; then
    log "Activated $(basename "$target"); Gateway remains disabled until setup"
    return 0
  fi

  if ! run_openclaw config validate; then
    warn "Candidate config validation failed. Restoring the previous release."
    ln -sfnT "$previous" "$OPENCLAW_CURRENT_LINK"
    systemctl restart openclaw.service || true
    wait_for_gateway_health 30 || warn "Previous Gateway failed its health check after restoration"
    return 1
  fi

  systemctl restart openclaw.service
  if wait_for_gateway_health 45; then
    return 0
  fi

  warn "Candidate Gateway failed its health check. Rolling back code."
  systemctl stop openclaw.service || true
  ln -sfnT "$previous" "$OPENCLAW_CURRENT_LINK"
  systemctl restart openclaw.service || true
  wait_for_gateway_health 30 || warn "Previous Gateway also failed its health check"
  return 1
}

acquire_release_lock() {
  require_root
  ensure_runtime_directory
  exec 8>/run/openclaw/release.lock
  flock -n 8 || die "Another OpenClaw release transaction is already running"
}

command_update() {
  require_root
  acquire_release_lock
  load_appliance_config
  local spec="${1:-$UPDATE_CHANNEL}"
  [[ -x "$NODE_CURRENT_LINK/bin/npm" ]] || die "Node.js runtime is missing"

  resolve_npm_metadata "$spec"
  local current_target current_version target
  current_target="$(readlink -f "$OPENCLAW_CURRENT_LINK" 2>/dev/null || true)"
  current_version="$(basename "$current_target" 2>/dev/null || true)"
  target="$OPENCLAW_RELEASES_DIR/$RESOLVED_VERSION"

  if [[ "$current_version" == "$RESOLVED_VERSION" ]]; then
    log "OpenClaw $RESOLVED_VERSION is already active"
    return 0
  fi

  log "Resolved $spec to OpenClaw $RESOLVED_VERSION"
  if config_exists; then
    command_backup
  fi
  install_openclaw_release "$RESOLVED_VERSION" "$RESOLVED_INTEGRITY" "$RESOLVED_TARBALL"

  if config_exists; then
    run_openclaw_bin "$target/bin/openclaw" config validate
  fi

  [[ -n "$current_target" && -d "$current_target" ]] || current_target="$target"
  systemctl stop openclaw.service >/dev/null 2>&1 || true
  if ! activate_release "$target" "$current_target"; then
    die "OpenClaw update failed and code was rolled back"
  fi
  prune_releases
  log "OpenClaw $RESOLVED_VERSION is active"
}

command_releases() {
  local plain="${1:-}"
  local active
  active="$(readlink -f "$OPENCLAW_CURRENT_LINK" 2>/dev/null || true)"
  local path
  while IFS= read -r path; do
    [[ -d "$path" ]] || continue
    if [[ "$plain" == "--plain" ]]; then
      basename "$path"
    elif [[ "$path" == "$active" ]]; then
      printf '* %s (active)\n' "$(basename "$path")"
    else
      printf '  %s\n' "$(basename "$path")"
    fi
  done < <(find "$OPENCLAW_RELEASES_DIR" -mindepth 1 -maxdepth 1 -type d ! -name '.*' -printf '%T@ %p\n' 2>/dev/null | sort -nr | cut -d' ' -f2-)
}

command_rollback() {
  require_root
  acquire_release_lock
  local requested="${1:-}"
  local active target
  active="$(readlink -f "$OPENCLAW_CURRENT_LINK" 2>/dev/null || true)"

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

  [[ -n "$target" && -x "$target/bin/openclaw" ]] || die "Requested rollback release is not installed"
  [[ -n "$active" && -d "$active" ]] || die "Active OpenClaw release cannot be resolved"
  [[ "$target" != "$active" ]] || {
    log "$(basename "$target") is already active"
    return 0
  }

  if config_exists; then
    run_openclaw_bin "$target/bin/openclaw" config validate
  fi
  systemctl stop openclaw.service >/dev/null 2>&1 || true
  if ! activate_release "$target" "$active"; then
    die "Rollback target failed and the previous release was restored"
  fi
  log "Rolled back to $(basename "$target")"
}

