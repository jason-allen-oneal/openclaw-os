# shellcheck shell=bash

oc_get() {
  local path="$1"
  local fallback="${2:-unknown}"
  local value
  if value="$(run_openclaw config get "$path" 2>/dev/null)" && [[ -n "$value" ]]; then
    printf '%s\n' "$value"
  else
    printf '%s\n' "$fallback"
  fi
}

command_status() {
  load_release_env
  load_appliance_config

  local configured="no"
  config_exists && configured="yes"
  local gateway_state podman_state hostd_state controller_state
  local bind port health controller_health latest_backup
  gateway_state="$(systemctl is-active openclaw.service 2>/dev/null || true)"
  podman_state="$(systemctl is-active openclaw-podman.service 2>/dev/null || true)"
  hostd_state="$(systemctl is-active openclaw-hostd.service 2>/dev/null || true)"
  controller_state="$(systemctl is-active openclaw-controller.service 2>/dev/null || true)"
  bind="unknown"
  port="18789"
  health="not-running"
  controller_health="not-running"

  if config_exists; then
    bind="$(oc_get gateway.bind loopback)"
    port="$(oc_get gateway.port 18789)"
  fi
  if [[ "$gateway_state" == "active" ]]; then
    if run_openclaw health --json --timeout 3000 2>/dev/null | jq -e '.ok == true' >/dev/null 2>&1; then
      health="healthy"
    else
      health="unhealthy"
    fi
  fi
  if [[ "$controller_state" == "active" ]]; then
    if curl --fail --silent --max-time 2 http://127.0.0.1:9080/healthz 2>/dev/null \
      | jq -e '.ok == true and .service == "openclaw-controller"' >/dev/null 2>&1; then
      controller_health="healthy"
    else
      controller_health="unhealthy"
    fi
  fi

  latest_backup="$(find /var/lib/openclaw/backups -maxdepth 1 -type f -name '*openclaw-backup.tar.gz' -printf '%T@ %f\n' 2>/dev/null | sort -nr | head -n 1 | cut -d' ' -f2- || true)"
  [[ -n "$latest_backup" ]] || latest_backup="none"

  cat <<STATUS
OpenClaw OS:       $OPENCLAW_OS_VERSION
Debian base:       $DEBIAN_CODENAME
Node.js:           $(/opt/node/current/bin/node --version 2>/dev/null || printf unavailable)
OpenClaw:          $(current_openclaw_version)
Configured:        $configured
Gateway service:   ${gateway_state:-inactive}
Gateway health:    $health
Sandbox service:   ${podman_state:-inactive}
Host status svc:   ${hostd_state:-inactive}
Controller svc:    ${controller_state:-inactive}
Controller health: $controller_health
Gateway bind:      $bind
Gateway port:      $port
LAN addresses:     $(hostname -I 2>/dev/null | xargs || true)
Latest backup:     $latest_backup
STATUS
}

ensure_runtime_directory() {
  require_root
  systemd-tmpfiles --create /etc/tmpfiles.d/openclaw.conf
  install -d -m 0700 -o openclaw -g openclaw /run/openclaw /run/openclaw/containers
}

sandbox_build() {
  require_root
  load_release_env
  ensure_runtime_directory
  log "Building $OPENCLAW_SANDBOX_IMAGE from the pinned Containerfile"
  run_podman_local build \
    --pull=always \
    --tag "$OPENCLAW_SANDBOX_IMAGE" \
    --file /usr/share/openclaw-os/sandbox/Containerfile \
    /usr/share/openclaw-os/sandbox
  run_podman_local image inspect "$OPENCLAW_SANDBOX_IMAGE" >/dev/null
  log "Sandbox image is ready"
}

sandbox_status() {
  load_release_env
  if run_podman_local image exists "$OPENCLAW_SANDBOX_IMAGE"; then
    echo "$OPENCLAW_SANDBOX_IMAGE: installed"
    run_podman_local image inspect "$OPENCLAW_SANDBOX_IMAGE" \
      --format 'ID={{.Id}} Created={{.Created}}' 2>/dev/null || true
  else
    echo "$OPENCLAW_SANDBOX_IMAGE: missing"
    return 1
  fi
}

sandbox_reset() {
  require_root
  if config_exists; then
    run_openclaw sandbox recreate --all --force || true
  fi
  local container_id
  while IFS= read -r container_id; do
    [[ -n "$container_id" ]] || continue
    run_podman_local rm -f "$container_id"
  done < <(run_podman_local ps -aq --filter label=openclaw.sandbox=1)
  log "Sandbox containers were removed and will be recreated on demand"
}

command_sandbox() {
  case "${1:-status}" in
    build) sandbox_build ;;
    status) sandbox_status ;;
    reset) sandbox_reset ;;
    *) die "Unknown sandbox action: ${1:-}" ;;
  esac
}
