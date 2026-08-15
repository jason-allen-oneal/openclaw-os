# shellcheck shell=bash

firewall_paths() {
  FIREWALL_PORTS_FILE="$(root_path /etc/openclaw/allowed-tcp-ports)"
  FIREWALL_LAN_PORTS_FILE="$(root_path /etc/openclaw/allowed-lan-tcp-ports)"
  FIREWALL_RULES_FILE="$(root_path /etc/nftables.conf)"
}

validate_port() {
  local port="$1"
  [[ "$port" =~ ^[0-9]+$ ]] || die "Invalid TCP port: $port"
  ((port >= 1 && port <= 65535)) || die "TCP port is out of range: $port"
}

format_port_elements() {
  local file="$1"
  local -a ports=()
  mapfile -t ports < <(grep -E '^[0-9]+$' "$file" 2>/dev/null | sort -nu)
  local port
  for port in "${ports[@]}"; do
    validate_port "$port"
  done
  if ((${#ports[@]} == 0)); then
    printf '\n'
    return 0
  fi
  local joined
  joined="$(printf '%s\n' "${ports[@]}" | paste -sd, - | sed 's/,/, /g')"
  printf '    elements = { %s }\n' "$joined"
}

firewall_render() {
  local apply=yes
  [[ "${1:-}" == "--no-apply" ]] && apply=no
  firewall_paths
  mkdir -p "$(dirname "$FIREWALL_PORTS_FILE")" "$(dirname "$FIREWALL_RULES_FILE")"
  touch "$FIREWALL_PORTS_FILE" "$FIREWALL_LAN_PORTS_FILE"

  local elements lan_elements
  elements="$(format_port_elements "$FIREWALL_PORTS_FILE")"
  lan_elements="$(format_port_elements "$FIREWALL_LAN_PORTS_FILE")"

  local temporary
  temporary="$(mktemp "${FIREWALL_RULES_FILE}.XXXXXX")"
  cat >"$temporary" <<RULES
#!/usr/sbin/nft -f
flush ruleset

table inet openclaw_filter {
  set allowed_tcp_ports {
    type inet_service
    flags interval
$elements
  }

  set allowed_lan_tcp_ports {
    type inet_service
    flags interval
$lan_elements
  }

  chain input {
    type filter hook input priority filter; policy drop;

    iifname "lo" accept
    ct state invalid drop
    ct state established,related accept
    ip protocol icmp accept
    ip6 nexthdr 58 accept
    udp sport 67 udp dport 68 accept
    udp sport 547 udp dport 546 accept
    tcp dport @allowed_tcp_ports ct state new accept
    ip saddr { 10.0.0.0/8, 100.64.0.0/10, 169.254.0.0/16, 172.16.0.0/12, 192.168.0.0/16 } tcp dport @allowed_lan_tcp_ports ct state new accept
    ip6 saddr { fc00::/7, fe80::/10 } tcp dport @allowed_lan_tcp_ports ct state new accept
  }

  chain forward {
    type filter hook forward priority filter; policy drop;
  }

  chain output {
    type filter hook output priority filter; policy accept;
  }
}
RULES

  if [[ "$apply" == "yes" && -z "$ROOT_PREFIX" ]]; then
    nft --check --file "$temporary"
  fi
  install -m 0644 "$temporary" "$FIREWALL_RULES_FILE"
  rm -f "$temporary"

  if [[ "$apply" == "yes" && -z "$ROOT_PREFIX" ]]; then
    systemctl reload-or-restart nftables.service
  fi
}

firewall_update_file() {
  require_root
  local file="$1"
  local action="$2"
  local port="$3"
  validate_port "$port"
  touch "$file"
  local temporary
  temporary="$(mktemp)"
  case "$action" in
    allow)
      { grep -E '^[0-9]+$' "$file" 2>/dev/null || true; printf '%s\n' "$port"; } | sort -nu >"$temporary"
      ;;
    deny)
      grep -E '^[0-9]+$' "$file" 2>/dev/null | grep -vx "$port" | sort -nu >"$temporary" || true
      ;;
    *)
      rm -f "$temporary"
      die "Unknown firewall file action: $action"
      ;;
  esac
  install -m 0644 "$temporary" "$file"
  rm -f "$temporary"
  firewall_render
}

firewall_allow() {
  firewall_paths
  firewall_update_file "$FIREWALL_PORTS_FILE" allow "$1"
}

firewall_deny() {
  firewall_paths
  firewall_update_file "$FIREWALL_PORTS_FILE" deny "$1"
}

firewall_allow_lan() {
  firewall_paths
  firewall_update_file "$FIREWALL_LAN_PORTS_FILE" allow "$1"
}

firewall_deny_lan() {
  firewall_paths
  firewall_update_file "$FIREWALL_LAN_PORTS_FILE" deny "$1"
}

command_firewall() {
  local action="${1:-list}"
  shift || true
  case "$action" in
    render)
      [[ -n "$ROOT_PREFIX" ]] || require_root
      firewall_render "${1:-}"
      ;;
    allow|deny|allow-lan|deny-lan)
      [[ $# -eq 1 ]] || die "Usage: openclaw-appliance firewall $action <port>"
      case "$action" in
        allow) firewall_allow "$1" ;;
        deny) firewall_deny "$1" ;;
        allow-lan) firewall_allow_lan "$1" ;;
        deny-lan) firewall_deny_lan "$1" ;;
      esac
      ;;
    list)
      firewall_paths
      echo "Any source:"
      grep -E '^[0-9]+$' "$FIREWALL_PORTS_FILE" 2>/dev/null | sort -nu || true
      echo "Private LAN and tailnet sources:"
      grep -E '^[0-9]+$' "$FIREWALL_LAN_PORTS_FILE" 2>/dev/null | sort -nu || true
      ;;
    *) die "Unknown firewall action: $action" ;;
  esac
}

