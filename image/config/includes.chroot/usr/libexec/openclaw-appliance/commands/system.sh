# shellcheck shell=bash

command_network() {
  require_root
  exec nmtui
}

command_logs() {
  local lines="${1:-200}"
  [[ "$lines" =~ ^[0-9]+$ ]] || die "Log line count must be numeric"
  journalctl -u openclaw.service -n "$lines" --no-pager
}

