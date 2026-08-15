#!/usr/bin/env bash

OPENCLAW_GATEWAY_TOKEN_FILE="${OPENCLAW_GATEWAY_TOKEN_FILE:-/etc/openclaw/gateway-token}"

openclaw_validate_gateway_credential_file() {
  local file="$1"
  [[ -f "$file" && ! -L "$file" ]] || return 1
  [[ "$(stat -c '%u:%a' "$file" 2>/dev/null)" == "0:600" ]] || return 1
  local size
  size="$(stat -c '%s' "$file" 2>/dev/null)" || return 1
  [[ "$size" =~ ^[0-9]+$ ]] || return 1
  ((size >= 16 && size <= 4097)) || return 1
}

openclaw_load_gateway_credential() {
  local file="${1:-$OPENCLAW_GATEWAY_TOKEN_FILE}"
  openclaw_validate_gateway_credential_file "$file" || return 1

  local -a lines=()
  mapfile -t lines <"$file"
  ((${#lines[@]} == 1)) || return 1
  local token="${lines[0]}"
  local LC_ALL=C
  [[ "$token" =~ ^[!-~]{16,4096}$ ]] || return 1

  OPENCLAW_GATEWAY_TOKEN="$token"
  export OPENCLAW_GATEWAY_TOKEN
}

openclaw_load_gateway_credential_if_present() {
  if [[ -e "$OPENCLAW_GATEWAY_TOKEN_FILE" ]]; then
    openclaw_load_gateway_credential "$OPENCLAW_GATEWAY_TOKEN_FILE" || {
      echo "[openclaw-os] ERROR: Gateway credential file is invalid" >&2
      return 1
    }
  fi
}

openclaw_ensure_gateway_credential() {
  [[ "$(id -u)" -eq 0 ]] || {
    echo "[openclaw-os] ERROR: Gateway credential creation requires root" >&2
    return 1
  }
  if [[ -e "$OPENCLAW_GATEWAY_TOKEN_FILE" ]]; then
    openclaw_load_gateway_credential "$OPENCLAW_GATEWAY_TOKEN_FILE"
    return
  fi

  install -d -m 0755 "$(dirname "$OPENCLAW_GATEWAY_TOKEN_FILE")"
  local temporary
  temporary="$(umask 077; mktemp "${OPENCLAW_GATEWAY_TOKEN_FILE}.XXXXXX")"
  if ! openssl rand -hex 32 >"$temporary" \
    || ! chown root:root "$temporary" \
    || ! chmod 0600 "$temporary" \
    || ! mv -T "$temporary" "$OPENCLAW_GATEWAY_TOKEN_FILE"; then
    rm -f "$temporary"
    return 1
  fi
  openclaw_load_gateway_credential "$OPENCLAW_GATEWAY_TOKEN_FILE"
}
