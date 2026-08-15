#!/usr/bin/env bash
set -Eeuo pipefail

ISO_PATH="${1:-}"
[[ -n "$ISO_PATH" && -f "$ISO_PATH" ]] || {
  echo "Usage: smoke-iso.sh <path-to-iso>" >&2
  exit 2
}

for command_name in qemu-system-x86_64 grep; do
  command -v "$command_name" >/dev/null 2>&1 || {
    echo "Missing command: $command_name" >&2
    exit 1
  }
done

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
[[ -n "$ovmf_code" ]] || {
  echo "OVMF firmware was not found" >&2
  exit 1
}

work_dir="$(mktemp -d)"
log_file="$work_dir/serial.log"
vars_copy="$work_dir/OVMF_VARS.fd"
cp "$ovmf_vars" "$vars_copy"
qemu_pid=""
cleanup() {
  if [[ -n "$qemu_pid" ]] && kill -0 "$qemu_pid" 2>/dev/null; then
    kill "$qemu_pid" 2>/dev/null || true
    wait "$qemu_pid" 2>/dev/null || true
  fi
  rm -rf "$work_dir"
}
trap cleanup EXIT

qemu-system-x86_64 \
  -machine q35,accel=tcg \
  -cpu max \
  -m 2048 \
  -smp 2 \
  -display none \
  -monitor none \
  -serial stdio \
  -no-reboot \
  -boot order=d \
  -drive "if=pflash,format=raw,readonly=on,file=$ovmf_code" \
  -drive "if=pflash,format=raw,file=$vars_copy" \
  -drive "file=$ISO_PATH,media=cdrom,readonly=on" \
  -nic user,model=virtio-net-pci \
  >"$log_file" 2>&1 &
qemu_pid=$!

for ((attempt = 1; attempt <= 240; attempt++)); do
  if grep -q 'OPENCLAW_OS_BOOT_OK' "$log_file"; then
    echo "UEFI live-boot smoke test passed."
    exit 0
  fi
  if ! kill -0 "$qemu_pid" 2>/dev/null; then
    echo "QEMU exited before the boot marker appeared." >&2
    cat "$log_file" >&2
    exit 1
  fi
  sleep 1
done

echo "Timed out before the OpenClaw OS boot marker appeared." >&2
cat "$log_file" >&2
exit 1
