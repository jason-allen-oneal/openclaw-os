# shellcheck shell=bash

command_gateway() {
  require_root
  local action="${1:-status}"
  case "$action" in
    start|stop|restart)
      systemctl "$action" openclaw.service
      ;;
    status)
      systemctl status openclaw.service --no-pager
      ;;
    *) die "Unknown gateway action: $action" ;;
  esac
}

command_access() {
  require_root
  config_exists || die "Run appliance setup before changing Gateway access"
  local action="${1:-status}"
  local port bind auth
  port="$(oc_get gateway.port 18789)"
  validate_port "$port"

  case "$action" in
    status)
      bind="$(oc_get gateway.bind loopback)"
      echo "Gateway bind: $bind"
      echo "Gateway port: $port"
      ;;
    lan)
      auth="$(oc_get gateway.auth.mode none)"
      [[ "$auth" == "token" || "$auth" == "password" ]] || \
        die "LAN access requires Gateway token or password authentication"

      firewall_deny "$port"
      firewall_allow_lan "$port"
      if ! run_openclaw config set gateway.bind lan; then
        firewall_deny_lan "$port" || true
        die "Could not set Gateway LAN binding"
      fi
      if ! systemctl restart openclaw.service || ! wait_for_gateway_health 30; then
        warn "LAN activation failed. Restoring loopback-only access."
        run_openclaw config set gateway.bind loopback || true
        firewall_deny_lan "$port" || true
        systemctl restart openclaw.service || true
        wait_for_gateway_health 30 || warn "Gateway did not recover after restoring loopback mode"
        die "Gateway LAN access was not activated"
      fi
      echo "Control UI is available on authenticated LAN addresses at port $port"
      hostname -I | tr ' ' '\n' | sed '/^$/d' | sed "s#^#http://#; s#\$#:$port/#"
      ;;
    loopback)
      firewall_deny "$port"
      firewall_deny_lan "$port"
      run_openclaw config set gateway.bind loopback
      systemctl restart openclaw.service
      wait_for_gateway_health 30 || die "Gateway did not pass the health check after switching to loopback"
      echo "Gateway access is now loopback-only"
      ;;
    *) die "Unknown access mode: $action" ;;
  esac
}

has_authorized_key() {
  local _username uid home
  while IFS=: read -r _username _ uid _ _ home _; do
    [[ "$uid" =~ ^[0-9]+$ ]] || continue
    ((uid >= 1000 && uid < 60000)) || continue
    if [[ -s "$home/.ssh/authorized_keys" ]]; then
      return 0
    fi
  done </etc/passwd
  return 1
}

command_ssh() {
  require_root
  local action="${1:-status}"
  case "$action" in
    status)
      systemctl is-enabled ssh.service 2>/dev/null || true
      systemctl is-active ssh.service 2>/dev/null || true
      ;;
    enable)
      has_authorized_key || die "No non-root user has a non-empty ~/.ssh/authorized_keys file"
      systemctl unmask ssh.service ssh.socket >/dev/null
      systemctl enable --now ssh.service
      firewall_allow 22
      log "Key-only SSH is enabled"
      ;;
    disable)
      systemctl disable --now ssh.service ssh.socket >/dev/null 2>&1 || true
      systemctl mask ssh.service ssh.socket >/dev/null 2>&1
      firewall_deny 22
      log "SSH is disabled and masked"
      ;;
    *) die "Unknown SSH action: $action" ;;
  esac
}

write_controller_environment() {
  local port temporary
  port="$(oc_get gateway.port 18789)"
  validate_port "$port"
  temporary="$(mktemp /etc/openclaw/controller.env.XXXXXX)"
  if ! printf 'OPENCLAW_CONTROLLER_GATEWAY_URL=ws://127.0.0.1:%s\n' "$port" >"$temporary" \
    || ! chown root:root "$temporary" \
    || ! chmod 0644 "$temporary" \
    || ! mv -T "$temporary" /etc/openclaw/controller.env; then
    rm -f "$temporary"
    die "Could not write controller Gateway endpoint"
  fi
}

wait_for_controller_health() {
  local attempts="${1:-20}"
  local response
  local i
  for ((i = 1; i <= attempts; i++)); do
    if response="$(curl --fail --silent --show-error --max-time 2 \
      http://127.0.0.1:9080/healthz 2>/dev/null)" \
      && jq -e '.ok == true and .service == "openclaw-controller"' \
        >/dev/null 2>&1 <<<"$response"; then
      return 0
    fi
    sleep 1
  done
  return 1
}

command_setup() {
  require_root
  [[ -t 0 && -t 1 ]] || die "Setup requires an interactive terminal"
  ensure_runtime_directory
  systemctl stop openclaw-controller.service openclaw.service >/dev/null 2>&1 || true

  openclaw_ensure_gateway_credential || die "Could not create or load the Gateway credential"
  sandbox_build

  log "Starting OpenClaw onboarding"
  run_openclaw onboard \
    --workspace /srv/openclaw/workspaces/main \
    --mode local \
    --flow advanced \
    --gateway-bind loopback \
    --gateway-auth token \
    --gateway-token-ref-env OPENCLAW_GATEWAY_TOKEN \
    --secret-input-mode ref \
    --suppress-gateway-token-output \
    --skip-daemon \
    --skip-skills \
    --skip-health

  run_openclaw config patch --file /usr/share/openclaw-os/defaults/openclaw.patch.json5
  run_openclaw config patch --file /usr/share/openclaw-os/policies/locked.json5
  run_openclaw config validate
  chown openclaw:openclaw "$OPENCLAW_CONFIG_FILE"
  chmod 0600 "$OPENCLAW_CONFIG_FILE"
  record_policy_state \
    locked \
    profile:locked \
    "$(sha256sum /usr/share/openclaw-os/policies/locked.json5 | awk '{print $1}')"
  write_controller_environment

  systemctl enable \
    openclaw-update-recovery.service \
    openclaw.service \
    openclaw-hostd.service \
    openclaw-controller.service \
    >/dev/null
  systemctl restart openclaw.service
  if ! wait_for_gateway_health 45; then
    systemctl status openclaw.service --no-pager || true
    die "Gateway did not become healthy after setup"
  fi

  systemctl restart openclaw-hostd.service
  systemctl restart openclaw-controller.service
  if ! wait_for_controller_health 20; then
    systemctl status openclaw-hostd.service openclaw-controller.service --no-pager || true
    die "OpenClaw OS controller did not become healthy after setup"
  fi

  touch /var/lib/openclaw/.appliance-initialized
  chown openclaw:openclaw /var/lib/openclaw/.appliance-initialized
  chmod 0600 /var/lib/openclaw/.appliance-initialized

  log "Running post-setup checks"
  run_openclaw secrets audit --check || warn "Secret audit reported findings"
  run_openclaw security audit --deep || warn "Security audit reported findings"

  cat <<'DONE'
OpenClaw setup completed.

The Gateway and the OpenClaw OS controller are bound to loopback. Use one of
these methods to reach the OpenClaw Control UI:

  sudo openclaw-appliance access lan
  SSH local port forwarding after enabling key-only SSH

The read-only appliance controller is available locally at:

  http://127.0.0.1:9080/api/v1/status

The locked execution profile is active. Review other profiles with:

  sudo openclaw-appliance policy list
  sudo openclaw-appliance policy status
  less /usr/share/openclaw-os/policies/README.md

Run `sudo openclaw-appliance status` for current health and addresses.
DONE
}
