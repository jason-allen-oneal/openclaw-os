#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'USAGE'
Usage: install-iso-vm.sh <path-to-iso> <uefi|bios>

Installs an OpenClaw OS ISO noninteractively onto a blank QEMU disk, detaches
the ISO, boots the installed system, and waits for a verification marker.
Preseeding and generated credentials remain outside the production image.
USAGE
}

ISO_PATH="${1:-}"
FIRMWARE_MODE="${2:-}"
[[ -n "$ISO_PATH" && -f "$ISO_PATH" ]] || { usage >&2; exit 2; }
case "$FIRMWARE_MODE" in uefi|bios) ;; *) usage >&2; exit 2 ;; esac

for command_name in awk curl date grep head jq openssl python3 \
  qemu-system-x86_64 realpath sed sha256sum stat tr truncate wc xorriso; do
  command -v "$command_name" >/dev/null 2>&1 || {
    printf 'Missing command: %s\n' "$command_name" >&2
    exit 1
  }
done

positive_integer() {
  local name="$1" value="$2"
  [[ "$value" =~ ^[1-9][0-9]*$ ]] || {
    printf '%s must be a positive integer, got: %s\n' "$name" "$value" >&2
    exit 2
  }
}

ISO_PATH="$(realpath "$ISO_PATH")"
INSTALL_TIMEOUT_SECONDS="${INSTALL_TIMEOUT_SECONDS:-1800}"
INSTALLED_BOOT_TIMEOUT_SECONDS="${INSTALLED_BOOT_TIMEOUT_SECONDS:-360}"
INSTALL_DISK_SIZE="${INSTALL_DISK_SIZE:-24G}"
positive_integer INSTALL_TIMEOUT_SECONDS "$INSTALL_TIMEOUT_SECONDS"
positive_integer INSTALLED_BOOT_TIMEOUT_SECONDS "$INSTALLED_BOOT_TIMEOUT_SECONDS"
[[ "$INSTALL_DISK_SIZE" =~ ^[1-9][0-9]*[GM]$ ]] || {
  printf 'INSTALL_DISK_SIZE must end in G or M, got: %s\n' "$INSTALL_DISK_SIZE" >&2
  exit 2
}

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
template_dir="$repo_root/tests/install"
# shellcheck disable=SC1091
source "$repo_root/image/config/includes.chroot/usr/share/openclaw-os/release.env"
expected_os_version="$(cat "$repo_root/VERSION")"
[[ "$expected_os_version" == "$OPENCLAW_OS_VERSION" ]] || {
  printf 'VERSION and release.env disagree: %s != %s\n' \
    "$expected_os_version" "$OPENCLAW_OS_VERSION" >&2
  exit 1
}
for template in preseed.cfg.in verify-installed.sh.in verify-installed.service; do
  [[ -f "$template_dir/$template" && ! -L "$template_dir/$template" ]] || {
    printf 'Missing or unsafe installer template: %s\n' "$template_dir/$template" >&2
    exit 1
  }
done

diagnostics_dir="${INSTALL_TEST_DIAGNOSTICS_DIR:-$repo_root/dist/install-test/$FIRMWARE_MODE}"
[[ "$diagnostics_dir" == /* ]] || diagnostics_dir="$PWD/$diagnostics_dir"
mkdir -p "$diagnostics_dir"
scratch_dir="$(mktemp -d)"
disk_path="${INSTALL_TEST_DISK_PATH:-$scratch_dir/openclaw-os-installed.raw}"

installer_serial="$diagnostics_dir/installer-serial.log"
installer_qemu_log="$diagnostics_dir/installer-qemu.log"
installed_serial="$diagnostics_dir/installed-serial.log"
installed_qemu_log="$diagnostics_dir/installed-qemu.log"
http_log="$diagnostics_dir/preseed-http.log"
metadata_file="$diagnostics_dir/metadata.txt"
installer_command_file="$diagnostics_dir/installer-qemu-command.txt"
installed_command_file="$diagnostics_dir/installed-qemu-command.txt"
installer_status_file="$diagnostics_dir/installer.exit-status"
installed_status_file="$diagnostics_dir/installed.exit-status"
installer_outcome_file="$diagnostics_dir/installer.outcome"
installed_outcome_file="$diagnostics_dir/installed.outcome"
disk_info_file="$diagnostics_dir/disk-info.json"
iso_listing_file="$diagnostics_dir/iso-installer-listing.txt"
rm -f "$diagnostics_dir"/*.log "$diagnostics_dir"/*.txt \
  "$diagnostics_dir"/*.json "$diagnostics_dir"/*.cfg \
  "$diagnostics_dir"/*.service "$diagnostics_dir"/*.sh \
  "$diagnostics_dir"/*.exit-status "$diagnostics_dir"/*.outcome
: >"$installer_serial"; : >"$installer_qemu_log"
: >"$installed_serial"; : >"$installed_qemu_log"; : >"$http_log"

server_pid=""; qemu_pid=""
cleanup() {
  local status=$?
  if [[ -n "$qemu_pid" ]] && kill -0 "$qemu_pid" 2>/dev/null; then
    kill "$qemu_pid" 2>/dev/null || true; wait "$qemu_pid" 2>/dev/null || true
  fi
  if [[ -n "$server_pid" ]] && kill -0 "$server_pid" 2>/dev/null; then
    kill "$server_pid" 2>/dev/null || true; wait "$server_pid" 2>/dev/null || true
  fi
  [[ "${INSTALL_TEST_RETAIN_DISK:-false}" == "true" ]] || rm -f "$disk_path"
  rm -rf "$scratch_dir"
  return "$status"
}
trap cleanup EXIT

print_log() {
  local label="$1" path="$2" line_count
  printf '%s\n' "--- ${label} ---" >&2
  [[ -s "$path" ]] || { printf '(empty)\n' >&2; return; }
  line_count="$(wc -l <"$path")"
  if ((line_count <= 500)); then cat "$path" >&2; else tail -n 500 "$path" >&2; fi
}

fail_with_diagnostics() {
  printf '%s\nDiagnostics retained at: %s\n' "$1" "$diagnostics_dir" >&2
  print_log 'installer serial console' "$installer_serial"
  print_log 'installer QEMU output' "$installer_qemu_log"
  print_log 'installed-system serial console' "$installed_serial"
  print_log 'installed-system QEMU output' "$installed_qemu_log"
  print_log 'preseed HTTP server' "$http_log"
}

write_disk_info() {
  local blocks block_size virtual_bytes allocated_bytes
  blocks="$(stat -c '%b' "$disk_path")"; block_size="$(stat -c '%B' "$disk_path")"
  virtual_bytes="$(stat -c '%s' "$disk_path")"; allocated_bytes="$((blocks * block_size))"
  jq -n --arg path "$disk_path" --arg format raw \
    --argjson virtualBytes "$virtual_bytes" --argjson allocatedBytes "$allocated_bytes" \
    '{format: $format, path: $path, virtualBytes: $virtualBytes, allocatedBytes: $allocatedBytes}' \
    >"$disk_info_file"
}

render_template() {
  local source="$1" destination="$2"
  TEMPLATE_SOURCE="$source" TEMPLATE_DESTINATION="$destination" \
  EXPECTED_OS_VERSION="$expected_os_version" \
  EXPECTED_OPENCLAW_VERSION="$OPENCLAW_VERSION" EXPECTED_NODE_VERSION="$NODE_VERSION" \
  EXPECTED_FIRMWARE_MODE="$FIRMWARE_MODE" TEMPLATE_BASE_URL="${base_url:-}" \
  TEMPLATE_PASSWORD_HASH="${password_hash:-}" python3 <<'PY'
from pathlib import Path
import os
source = Path(os.environ["TEMPLATE_SOURCE"]).read_text()
replacements = {
    "@EXPECTED_OS_VERSION@": os.environ["EXPECTED_OS_VERSION"],
    "@EXPECTED_OPENCLAW_VERSION@": os.environ["EXPECTED_OPENCLAW_VERSION"],
    "@EXPECTED_NODE_VERSION@": os.environ["EXPECTED_NODE_VERSION"],
    "@FIRMWARE_MODE@": os.environ["EXPECTED_FIRMWARE_MODE"],
    "@BASE_URL@": os.environ["TEMPLATE_BASE_URL"],
    "@PASSWORD_HASH@": os.environ["TEMPLATE_PASSWORD_HASH"],
}
for token, value in replacements.items():
    source = source.replace(token, value)
if "@" in source:
    raise SystemExit("unresolved template token")
Path(os.environ["TEMPLATE_DESTINATION"]).write_text(source)
PY
}

INSTALLER_KERNEL_PATH="$scratch_dir/installer-vmlinuz"
INSTALLER_INITRD_PATH="$scratch_dir/installer-initrd.gz"
INSTALLER_ISO_PREFIX=""
xorriso -indev "$ISO_PATH" -find / -exec lsdl -- >"$iso_listing_file" 2>&1 || true
for prefix in /install.amd /install; do
  rm -f "$INSTALLER_KERNEL_PATH" "$INSTALLER_INITRD_PATH"
  if xorriso -osirrox on -indev "$ISO_PATH" \
    -extract "$prefix/vmlinuz" "$INSTALLER_KERNEL_PATH" >/dev/null 2>&1 \
    && xorriso -osirrox on -indev "$ISO_PATH" \
      -extract "$prefix/initrd.gz" "$INSTALLER_INITRD_PATH" >/dev/null 2>&1; then
    INSTALLER_ISO_PREFIX="$prefix"; break
  fi
done
[[ -n "$INSTALLER_ISO_PREFIX" ]] || {
  fail_with_diagnostics 'Could not locate the Debian Installer kernel and initrd in the ISO.'
  exit 1
}

ovmf_code=""; ovmf_vars_template=""; ovmf_vars_copy=""
if [[ "$FIRMWARE_MODE" == "uefi" ]]; then
  for pair in \
    '/usr/share/OVMF/OVMF_CODE_4M.fd:/usr/share/OVMF/OVMF_VARS_4M.fd' \
    '/usr/share/OVMF/OVMF_CODE.fd:/usr/share/OVMF/OVMF_VARS.fd' \
    '/usr/share/edk2/ovmf/OVMF_CODE.fd:/usr/share/edk2/ovmf/OVMF_VARS.fd'; do
    code="${pair%%:*}"; vars="${pair#*:}"
    [[ -f "$code" && -f "$vars" ]] || continue
    ovmf_code="$code"; ovmf_vars_template="$vars"; break
  done
  [[ -n "$ovmf_code" ]] || { fail_with_diagnostics 'OVMF firmware was not found.'; exit 1; }
  ovmf_vars_copy="$scratch_dir/OVMF_VARS.fd"; cp "$ovmf_vars_template" "$ovmf_vars_copy"
fi

http_root="$scratch_dir/http"; mkdir -p "$http_root"
password_hash="$(openssl passwd -6 "$(openssl rand -hex 32)")"
port="$((18000 + RANDOM % 10000))"; base_url="http://10.0.2.2:${port}"
render_template "$template_dir/verify-installed.sh.in" "$http_root/verify-installed.sh"
render_template "$template_dir/preseed.cfg.in" "$http_root/preseed.cfg"
cp "$template_dir/verify-installed.service" "$http_root/verify-installed.service"
chmod 0755 "$http_root/verify-installed.sh"
sed -E 's#^(d-i passwd/user-password-crypted password ).*$#\1[REDACTED]#' \
  "$http_root/preseed.cfg" >"$diagnostics_dir/preseed.redacted.cfg"
cp "$http_root/verify-installed.sh" "$diagnostics_dir/verify-installed.sh"
cp "$http_root/verify-installed.service" "$diagnostics_dir/verify-installed.service"

python3 -m http.server "$port" --bind 0.0.0.0 --directory "$http_root" >"$http_log" 2>&1 &
server_pid=$!
for _ in {1..30}; do
  curl --fail --silent "http://127.0.0.1:${port}/preseed.cfg" >/dev/null && break
  kill -0 "$server_pid" 2>/dev/null || { fail_with_diagnostics 'Preseed server exited.'; exit 1; }
  sleep 0.2
done
curl --fail --silent "http://127.0.0.1:${port}/preseed.cfg" >/dev/null || {
  fail_with_diagnostics 'Preseed server did not become ready.'; exit 1
}

truncate -s "$INSTALL_DISK_SIZE" "$disk_path"; write_disk_info
qemu_version="$(qemu-system-x86_64 --version | sed -n '1p')"
{
  printf 'timestamp_utc=%s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
  printf 'firmware_mode=%s\niso_path=%s\n' "$FIRMWARE_MODE" "$ISO_PATH"
  printf 'iso_size_bytes=%s\niso_sha256=%s\n' "$(stat -c '%s' "$ISO_PATH")" \
    "$(sha256sum "$ISO_PATH" | awk '{print $1}')"
  printf 'installer_iso_prefix=%s\ndisk_size=%s\n' "$INSTALLER_ISO_PREFIX" "$INSTALL_DISK_SIZE"
  printf 'install_timeout_seconds=%s\ninstalled_boot_timeout_seconds=%s\n' \
    "$INSTALL_TIMEOUT_SECONDS" "$INSTALLED_BOOT_TIMEOUT_SECONDS"
  printf 'qemu_version=%s\nexpected_os_version=%s\n' "$qemu_version" "$expected_os_version"
  printf 'expected_openclaw_version=%s\nexpected_node_version=%s\n' "$OPENCLAW_VERSION" "$NODE_VERSION"
  if [[ "$FIRMWARE_MODE" == "uefi" ]]; then
    printf 'ovmf_code=%s\novmf_vars_template=%s\n' "$ovmf_code" "$ovmf_vars_template"
  fi
} >"$metadata_file"

machine_type=pc
if [[ "$FIRMWARE_MODE" == "uefi" ]]; then
  machine_type=q35
fi
kernel_append="auto=true priority=critical locale=en_US.UTF-8 keymap=us hostname=openclaw-ci domain=local netcfg/choose_interface=auto url=${base_url}/preseed.cfg console=tty0 console=ttyS0,115200n8 DEBIAN_FRONTEND=text ---"
installer_command=(qemu-system-x86_64 -machine "${machine_type},accel=tcg" -cpu max \
  -m 3072 -smp 2 -display none -monitor none -serial "file:${installer_serial}" \
  -no-reboot -kernel "$INSTALLER_KERNEL_PATH" -initrd "$INSTALLER_INITRD_PATH" \
  -append "$kernel_append" -drive "file=${disk_path},if=virtio,format=raw,cache=unsafe" \
  -drive "file=${ISO_PATH},media=cdrom,readonly=on,format=raw" \
  -nic "user,model=virtio-net-pci")
if [[ "$FIRMWARE_MODE" == "uefi" ]]; then
  installer_command+=(-drive "if=pflash,format=raw,readonly=on,file=${ovmf_code}" \
    -drive "if=pflash,format=raw,file=${ovmf_vars_copy}")
fi
printf '%q ' "${installer_command[@]}" >"$installer_command_file"; printf '\n' >>"$installer_command_file"

printf 'Installing to a blank %s disk under %s QEMU...\n' "$INSTALL_DISK_SIZE" "$FIRMWARE_MODE"
"${installer_command[@]}" >"$installer_qemu_log" 2>&1 & qemu_pid=$!
deadline=$((SECONDS + INSTALL_TIMEOUT_SECONDS))
while ((SECONDS < deadline)); do
  if ! kill -0 "$qemu_pid" 2>/dev/null; then
    status=0; wait "$qemu_pid" || status=$?; qemu_pid=""; printf '%s\n' "$status" >"$installer_status_file"
    [[ "$status" -eq 0 ]] || { printf 'qemu-error\n' >"$installer_outcome_file"; fail_with_diagnostics 'Installer VM failed.'; exit 1; }
    printf 'guest-powered-off\n' >"$installer_outcome_file"; break
  fi
  sleep 2
done
[[ -z "$qemu_pid" ]] || {
  kill "$qemu_pid" 2>/dev/null || true; wait "$qemu_pid" 2>/dev/null || true; qemu_pid=""
  printf 'timeout\n' >"$installer_outcome_file"; fail_with_diagnostics 'Installer timed out.'; exit 1
}
write_disk_info

installed_command=(qemu-system-x86_64 -machine "${machine_type},accel=tcg" -cpu max \
  -m 3072 -smp 2 -display none -monitor none -serial "file:${installed_serial}" \
  -no-reboot -boot "order=c,menu=off,strict=on" \
  -drive "file=${disk_path},if=virtio,format=raw,cache=unsafe" \
  -nic "user,model=virtio-net-pci")
if [[ "$FIRMWARE_MODE" == "uefi" ]]; then
  installed_command+=(-drive "if=pflash,format=raw,readonly=on,file=${ovmf_code}" \
    -drive "if=pflash,format=raw,file=${ovmf_vars_copy}")
fi
printf '%q ' "${installed_command[@]}" >"$installed_command_file"; printf '\n' >>"$installed_command_file"

printf 'Booting installed %s system with the ISO detached...\n' "$FIRMWARE_MODE"
"${installed_command[@]}" >"$installed_qemu_log" 2>&1 & qemu_pid=$!
deadline=$((SECONDS + INSTALLED_BOOT_TIMEOUT_SECONDS))
while ((SECONDS < deadline)); do
  if grep -Fq 'OPENCLAW_OS_INSTALLED_BOOT_OK' "$installed_serial"; then
    printf 'marker-detected\n' >"$installed_outcome_file"
    printf 'terminated-after-marker\n' >"$installed_status_file"
    printf 'Blank-disk %s installation test passed.\n' "$FIRMWARE_MODE"; exit 0
  fi
  if grep -Fq 'OPENCLAW_OS_INSTALL_VERIFY_FAIL:' "$installed_serial"; then
    printf 'verifier-failed\n' >"$installed_outcome_file"
    fail_with_diagnostics 'Installed-system verifier failed.'; exit 1
  fi
  if ! kill -0 "$qemu_pid" 2>/dev/null; then
    status=0; wait "$qemu_pid" || status=$?; qemu_pid=""; printf '%s\n' "$status" >"$installed_status_file"
    printf 'qemu-exited-before-marker\n' >"$installed_outcome_file"
    fail_with_diagnostics 'Installed system exited before verification.'; exit 1
  fi
  sleep 1
done
kill "$qemu_pid" 2>/dev/null || true; wait "$qemu_pid" 2>/dev/null || true; qemu_pid=""
printf 'timeout-before-marker\n' >"$installed_outcome_file"
fail_with_diagnostics 'Installed-system verification timed out.'; exit 1
