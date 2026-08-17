#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'USAGE'
Usage: smoke-iso.sh <path-to-iso>

Boots an OpenClaw OS ISO with OVMF/QEMU, captures the serial console, and
waits for the OPENCLAW_OS_BOOT_OK marker. In CI, it also installs the ISO onto
blank UEFI and BIOS disks and verifies each installed system after the ISO is
detached. Set SMOKE_RUN_INSTALL_TESTS=false to disable the install phase.
Diagnostics are retained under SMOKE_DIAGNOSTICS_DIR, or dist/smoke-test by
default.
USAGE
}

ISO_PATH="${1:-}"
if [[ -z "$ISO_PATH" || ! -f "$ISO_PATH" ]]; then
  usage >&2
  exit 2
fi

for command_name in qemu-system-x86_64 grep realpath sha256sum stat; do
  command -v "$command_name" >/dev/null 2>&1 || {
    printf 'Missing command: %s\n' "$command_name" >&2
    exit 1
  }
done

ISO_PATH="$(realpath "$ISO_PATH")"
SMOKE_TIMEOUT_SECONDS="${SMOKE_TIMEOUT_SECONDS:-240}"
if [[ ! "$SMOKE_TIMEOUT_SECONDS" =~ ^[1-9][0-9]*$ ]]; then
  printf 'SMOKE_TIMEOUT_SECONDS must be a positive integer, got: %s\n' \
    "$SMOKE_TIMEOUT_SECONDS" >&2
  exit 2
fi

run_install_tests="${SMOKE_RUN_INSTALL_TESTS:-${CI:-false}}"
case "$run_install_tests" in
  true|false)
    ;;
  *)
    printf 'SMOKE_RUN_INSTALL_TESTS must be true or false, got: %s\n' \
      "$run_install_tests" >&2
    exit 2
    ;;
esac

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
diagnostics_dir="${SMOKE_DIAGNOSTICS_DIR:-$repo_root/dist/smoke-test}"
if [[ "$diagnostics_dir" != /* ]]; then
  diagnostics_dir="$PWD/$diagnostics_dir"
fi

mkdir -p "$diagnostics_dir"
serial_log="$diagnostics_dir/serial.log"
qemu_log="$diagnostics_dir/qemu.log"
metadata_file="$diagnostics_dir/metadata.txt"
command_file="$diagnostics_dir/qemu-command.txt"
exit_status_file="$diagnostics_dir/qemu.exit-status"
outcome_file="$diagnostics_dir/outcome.txt"
rm -f \
  "$serial_log" \
  "$qemu_log" \
  "$metadata_file" \
  "$command_file" \
  "$exit_status_file" \
  "$outcome_file"
: >"$serial_log"
: >"$qemu_log"

ovmf_code=""
ovmf_vars=""
for pair in \
  '/usr/share/OVMF/OVMF_CODE_4M.fd:/usr/share/OVMF/OVMF_VARS_4M.fd' \
  '/usr/share/OVMF/OVMF_CODE.fd:/usr/share/OVMF/OVMF_VARS.fd' \
  '/usr/share/edk2/ovmf/OVMF_CODE.fd:/usr/share/edk2/ovmf/OVMF_VARS.fd'; do
  code="${pair%%:*}"
  vars="${pair#*:}"
  if [[ -f "$code" && -f "$vars" ]]; then
    ovmf_code="$code"
    ovmf_vars="$vars"
    break
  fi
done
if [[ -z "$ovmf_code" ]]; then
  printf 'OVMF firmware was not found\n' >&2
  exit 1
fi

scratch_dir="$(mktemp -d)"
vars_copy="$scratch_dir/OVMF_VARS.fd"
cp "$ovmf_vars" "$vars_copy"
qemu_pid=""

stop_qemu() {
  if [[ -n "$qemu_pid" ]] && kill -0 "$qemu_pid" 2>/dev/null; then
    kill "$qemu_pid" 2>/dev/null || true
    wait "$qemu_pid" 2>/dev/null || true
  fi
  qemu_pid=""
}

cleanup() {
  local status=$?
  stop_qemu
  rm -rf "$scratch_dir"
  return "$status"
}
trap cleanup EXIT

qemu_version="$(qemu-system-x86_64 --version | sed -n '1p')"
{
  printf 'timestamp_utc=%s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
  printf 'iso_path=%s\n' "$ISO_PATH"
  printf 'iso_size_bytes=%s\n' "$(stat -c '%s' "$ISO_PATH")"
  printf 'iso_sha256=%s\n' "$(sha256sum "$ISO_PATH" | awk '{print $1}')"
  printf 'timeout_seconds=%s\n' "$SMOKE_TIMEOUT_SECONDS"
  printf 'run_install_tests=%s\n' "$run_install_tests"
  printf 'qemu_version=%s\n' "$qemu_version"
  printf 'ovmf_code=%s\n' "$ovmf_code"
  printf 'ovmf_vars_template=%s\n' "$ovmf_vars"
  printf 'kernel=%s\n' "$(uname -srvmo)"
} >"$metadata_file"

qemu_command=(
  qemu-system-x86_64
  -machine "q35,accel=tcg"
  -cpu max
  -m 2048
  -smp 2
  -display none
  -monitor none
  -serial "file:${serial_log}"
  -no-reboot
  -boot "order=d,menu=off,strict=on"
  -drive "if=pflash,format=raw,readonly=on,file=${ovmf_code}"
  -drive "if=pflash,format=raw,file=${vars_copy}"
  -drive "file=${ISO_PATH},media=cdrom,readonly=on,format=raw"
  -nic "user,model=virtio-net-pci"
)
printf '%q ' "${qemu_command[@]}" >"$command_file"
printf '\n' >>"$command_file"

print_log() {
  local label="$1"
  local path="$2"
  local line_count

  printf '%s\n' "--- ${label} ---" >&2
  if [[ ! -s "$path" ]]; then
    printf '(empty)\n' >&2
    return
  fi

  line_count="$(wc -l <"$path")"
  if ((line_count <= 400)); then
    cat "$path" >&2
  else
    printf '(showing final 400 of %s lines)\n' "$line_count" >&2
    tail -n 400 "$path" >&2
  fi
}

fail_with_diagnostics() {
  local message="$1"
  printf '%s\n' "$message" >&2
  printf 'Diagnostics retained at: %s\n' "$diagnostics_dir" >&2
  print_log 'serial console' "$serial_log"
  print_log 'QEMU output' "$qemu_log"
}

run_blank_disk_tests() {
  local firmware
  if [[ "$run_install_tests" != "true" ]]; then
    return 0
  fi

  [[ -x "$repo_root/scripts/install-iso-vm.sh" ]] || {
    printf 'Missing executable installer test harness: %s\n' \
      "$repo_root/scripts/install-iso-vm.sh" >&2
    return 1
  }

  for firmware in uefi bios; do
    printf 'Running blank-disk %s installation test...\n' "$firmware"
    INSTALL_TEST_DIAGNOSTICS_DIR="$diagnostics_dir/install-$firmware" \
      "$repo_root/scripts/install-iso-vm.sh" "$ISO_PATH" "$firmware"
  done
}

pass_live_boot() {
  printf 'marker-detected\n' >"$outcome_file"
  printf 'terminated-after-marker\n' >"$exit_status_file"
  stop_qemu
  printf 'UEFI live-boot smoke test passed.\n'
  run_blank_disk_tests
  if [[ "$run_install_tests" == "true" ]]; then
    printf 'UEFI and BIOS blank-disk installation tests passed.\n'
  fi
}

printf 'Booting %s under UEFI QEMU...\n' "$ISO_PATH"
"${qemu_command[@]}" >"$qemu_log" 2>&1 &
qemu_pid=$!

deadline=$((SECONDS + SMOKE_TIMEOUT_SECONDS))
while ((SECONDS < deadline)); do
  if grep -Fq 'OPENCLAW_OS_BOOT_OK' "$serial_log"; then
    pass_live_boot
    exit 0
  fi

  if ! kill -0 "$qemu_pid" 2>/dev/null; then
    qemu_status=0
    if wait "$qemu_pid"; then
      qemu_status=0
    else
      qemu_status=$?
    fi
    qemu_pid=""
    printf '%s\n' "$qemu_status" >"$exit_status_file"
    printf 'qemu-exited-before-marker\n' >"$outcome_file"
    fail_with_diagnostics 'QEMU exited before the boot marker appeared.'
    exit 1
  fi

  sleep 1
done

if grep -Fq 'OPENCLAW_OS_BOOT_OK' "$serial_log"; then
  pass_live_boot
  exit 0
fi

stop_qemu
printf 'timeout-before-marker\n' >"$exit_status_file"
printf 'timeout-before-marker\n' >"$outcome_file"
fail_with_diagnostics 'Timed out before the OpenClaw OS boot marker appeared.'
exit 1
