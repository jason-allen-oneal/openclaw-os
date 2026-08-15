# shellcheck shell=bash

command_backup() {
  config_exists || {
    log "No OpenClaw config exists, so there is nothing to back up"
    return 0
  }
  load_appliance_config
  if [[ "$(id -u)" -eq 0 ]]; then
    install -d -m 0700 -o openclaw -g openclaw /var/lib/openclaw/backups
  else
    mkdir -p /var/lib/openclaw/backups
    chmod 0700 /var/lib/openclaw/backups
  fi

  local lock_file=/var/lib/openclaw/backups/.backup.lock
  if [[ "$(id -u)" -eq 0 ]]; then
    touch "$lock_file"
    chown openclaw:openclaw "$lock_file"
  fi
  exec 9>"$lock_file"
  if ! flock -n 9; then
    warn "Another backup is already running"
    return 0
  fi

  local -a args=(backup create --output /var/lib/openclaw/backups --verify)
  if [[ "${BACKUP_INCLUDE_WORKSPACE,,}" != "yes" ]]; then
    args+=(--no-include-workspace)
  fi
  run_openclaw "${args[@]}"

  if [[ "$BACKUP_RETENTION_DAYS" =~ ^[0-9]+$ ]]; then
    find /var/lib/openclaw/backups -maxdepth 1 -type f \
      -name '*openclaw-backup.tar.gz' -mtime "+$BACKUP_RETENTION_DAYS" -delete
  fi
}

run_audit_command() {
  local output_file="$1"
  shift
  local status=0
  if run_openclaw "$@" --json >"$output_file"; then
    status=0
  else
    status=$?
  fi
  chmod 0600 "$output_file"
  return "$status"
}

command_audit() {
  local mode="${1:-standard}"
  [[ "$mode" == "standard" || "$mode" == "deep" ]] || die "Audit mode must be standard or deep"
  config_exists || die "OpenClaw is not configured"

  if [[ "$(id -u)" -eq 0 ]]; then
    install -d -m 0700 -o openclaw -g openclaw /var/log/openclaw/audits
  else
    mkdir -p /var/log/openclaw/audits
    chmod 0700 /var/log/openclaw/audits
  fi
  local timestamp directory
  timestamp="$(date --utc +%Y%m%dT%H%M%SZ)"
  directory="/var/log/openclaw/audits/$timestamp"
  if [[ "$(id -u)" -eq 0 ]]; then
    install -d -m 0700 -o openclaw -g openclaw "$directory"
  else
    mkdir -p "$directory"
    chmod 0700 "$directory"
  fi

  local config_rc=0 secrets_rc=0 security_rc=0
  run_audit_command "$directory/config.json" config validate || config_rc=$?
  run_audit_command "$directory/secrets.json" secrets audit --check || secrets_rc=$?
  if [[ "$mode" == "deep" ]]; then
    run_audit_command "$directory/security.json" security audit --deep || security_rc=$?
  else
    run_audit_command "$directory/security.json" security audit || security_rc=$?
  fi
  if [[ "$(id -u)" -eq 0 ]]; then
    chown -R openclaw:openclaw "$directory"
  fi

  cat <<SUMMARY
Audit directory: $directory
Config result:   $config_rc
Secrets result:  $secrets_rc
Security result: $security_rc
SUMMARY
  jq '.summary // .' "$directory/security.json" 2>/dev/null || true

  if ((config_rc != 0 || secrets_rc != 0 || security_rc != 0)); then
    return 1
  fi
}

