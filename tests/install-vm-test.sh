#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SCRIPT="$ROOT_DIR/scripts/install-iso-vm.sh"
SMOKE_SCRIPT="$ROOT_DIR/scripts/smoke-iso.sh"
TEMPLATE_DIR="$ROOT_DIR/tests/install"
VERIFY_TEMPLATE="$TEMPLATE_DIR/verify-installed.sh.in"
PRESEED_TEMPLATE="$TEMPLATE_DIR/preseed.cfg.in"
SERVICE_TEMPLATE="$TEMPLATE_DIR/verify-installed.service"

fail() {
  printf 'Install VM test failed: %s\n' "$1" >&2
  exit 1
}

for file in "$INSTALL_SCRIPT" "$SMOKE_SCRIPT" "$VERIFY_TEMPLATE" \
  "$PRESEED_TEMPLATE" "$SERVICE_TEMPLATE"; do
  [[ -f "$file" && ! -L "$file" ]] || fail "missing or unsafe file: $file"
done
[[ -x "$INSTALL_SCRIPT" ]] || fail 'installer harness is not executable'
[[ -x "$SMOKE_SCRIPT" ]] || fail 'smoke harness is not executable'

bash -n "$INSTALL_SCRIPT"
bash -n "$SMOKE_SCRIPT"
bash -n "$VERIFY_TEMPLATE"

for marker in OPENCLAW_OS_INSTALLED_BOOT_OK OPENCLAW_OS_INSTALL_VERIFY_FAIL \
  /boot/efi/EFI/BOOT/BOOTX64.EFI /boot/grub/i386-pc; do
  grep -Fq "$marker" "$VERIFY_TEMPLATE" \
    || fail "installed verifier is missing contract marker: $marker"
done

for marker in debian-installer/exit/poweroff /dev/vda @PASSWORD_HASH@ @BASE_URL@; do
  grep -Fq "$marker" "$PRESEED_TEMPLATE" \
    || fail "preseed template is missing contract marker: $marker"
done

# The following patterns intentionally verify literal shell source text.
# shellcheck disable=SC2016
grep -Fq 'INSTALL_TEST_DIAGNOSTICS_DIR="$diagnostics_dir/install-$firmware"' \
  "$SMOKE_SCRIPT" || fail 'smoke harness does not retain per-firmware diagnostics'
grep -Fq 'for firmware in uefi bios' "$SMOKE_SCRIPT" \
  || fail 'smoke harness does not cover UEFI and BIOS installs'
# shellcheck disable=SC2016
grep -Fq 'SMOKE_RUN_INSTALL_TESTS:-${CI:-false}' "$SMOKE_SCRIPT" \
  || fail 'CI does not enable installed-system tests by default'

if grep -R -E -n \
  'preseed\.cfg|ci-install-test|openclaw-ci-install-verifier|passwd/user-password' \
  "$ROOT_DIR/image" >/dev/null 2>&1; then
  fail 'CI-only installer material is present in the production image tree'
fi

if grep -E '^d-i passwd/(user-password|root-password)' "$PRESEED_TEMPLATE" \
  | grep -Fv '@PASSWORD_HASH@' >/dev/null; then
  fail 'preseed template contains a static CI password field'
fi

grep -Fq 'openssl rand -hex 32' "$INSTALL_SCRIPT" \
  || fail 'installer password is not generated per run'
grep -Fq '[REDACTED]' "$INSTALL_SCRIPT" \
  || fail 'preseed diagnostics are not redacted'
# shellcheck disable=SC2016
grep -Fq 'file=${ISO_PATH},media=cdrom' "$INSTALL_SCRIPT" \
  || fail 'installer does not attach the source ISO'
# shellcheck disable=SC2016
if grep -Fq 'file=${ISO_PATH},media=cdrom' \
  <(sed -n '/installed_command=(/,/^)/p' "$INSTALL_SCRIPT"); then
  fail 'installed-system boot still attaches the source ISO'
fi

echo 'Install VM harness tests passed.'
