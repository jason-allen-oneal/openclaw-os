#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SCRIPT="$ROOT_DIR/scripts/install-iso-vm.sh"
SMOKE_SCRIPT="$ROOT_DIR/scripts/smoke-iso.sh"
MATRIX_RUNNER="$ROOT_DIR/scripts/installed-system-test.sh"
TEMPLATE_DIR="$ROOT_DIR/tests/install"
MATRIX_DIR="$ROOT_DIR/tests/installed-system"
VERIFY_TEMPLATE="$TEMPLATE_DIR/verify-installed.sh.in"
PRESEED_TEMPLATE="$TEMPLATE_DIR/preseed.cfg.in"
SERVICE_TEMPLATE="$TEMPLATE_DIR/verify-installed.service"
UPGRADE_TEMPLATE="$MATRIX_DIR/verify-installed-upgrade.sh.in"
UPGRADE_SERVICE="$MATRIX_DIR/verify-installed-upgrade.service"
MATRIX_FILE="$MATRIX_DIR/matrix.json"

fail() {
  printf 'Install VM test failed: %s\n' "$1" >&2
  exit 1
}

for file in \
  "$INSTALL_SCRIPT" \
  "$SMOKE_SCRIPT" \
  "$MATRIX_RUNNER" \
  "$VERIFY_TEMPLATE" \
  "$PRESEED_TEMPLATE" \
  "$SERVICE_TEMPLATE" \
  "$UPGRADE_TEMPLATE" \
  "$UPGRADE_SERVICE" \
  "$MATRIX_FILE"; do
  [[ -f "$file" && ! -L "$file" ]] || fail "missing or unsafe file: $file"
done

for file in "$INSTALL_SCRIPT" "$SMOKE_SCRIPT" "$MATRIX_RUNNER"; do
  [[ -x "$file" ]] || fail "required harness is not executable: $file"
done

bash -n "$INSTALL_SCRIPT"
bash -n "$SMOKE_SCRIPT"
bash -n "$MATRIX_RUNNER"
bash -n "$VERIFY_TEMPLATE"
bash -n "$UPGRADE_TEMPLATE"

jq -e '
  .schemaVersion == 1
  and (.cases | type == "array" and length >= 2)
  and ([.cases[].firmware] | index("uefi") != null)
  and ([.cases[].firmware] | index("bios") != null)
  and (any(.cases[]; .runUpgradePath))
  and (.upgrade.fromVersion | type == "string" and length > 0)
  and (.upgrade.fromTarball
    == ("https://registry.npmjs.org/openclaw/-/openclaw-"
      + .upgrade.fromVersion + ".tgz"))
  and (.upgrade.fromIntegrity
    | type == "string" and test("^sha512-[A-Za-z0-9+/=]+$"))
  and (.upgrade.fromReleaseCommit
    | type == "string" and test("^[a-f0-9]{40}$"))
' "$MATRIX_FILE" >/dev/null || fail 'installed-system matrix schema is invalid'

for marker in \
  OPENCLAW_OS_INSTALLED_BOOT_OK \
  OPENCLAW_OS_INSTALL_VERIFY_FAIL \
  /boot/efi/EFI/BOOT/BOOTX64.EFI \
  /boot/grub/i386-pc; do
  grep -Fq "$marker" "$VERIFY_TEMPLATE" \
    || fail "base installed verifier is missing contract marker: $marker"
  grep -Fq "$marker" "$UPGRADE_TEMPLATE" \
    || fail "upgrade verifier is missing contract marker: $marker"
done

for marker in \
  OPENCLAW_OS_UPGRADE_STEP_OK \
  verify_openclaw_release_metadata \
  "update stage \"\$from_version\" --allow-untested" \
  'update apply --allow-untested' \
  "rollback \"\$from_version\"" \
  stage-candidate \
  upgrade-candidate \
  rollback-previous \
  reapply-candidate \
  pending-release-mismatch; do
  grep -Fq "$marker" "$UPGRADE_TEMPLATE" \
    || fail "upgrade verifier is missing transaction marker: $marker"
done

for token in \
  @CASE_ID@ \
  @MACHINE@ \
  @RUN_UPGRADE_PATH@ \
  @UPGRADE_FROM_VERSION@ \
  @UPGRADE_FROM_TARBALL@ \
  @UPGRADE_FROM_INTEGRITY@ \
  @UPGRADE_FROM_RELEASE_COMMIT@; do
  grep -Fq "$token" "$UPGRADE_TEMPLATE" \
    || fail "upgrade verifier is missing template token: $token"
done

grep -Fq 'TimeoutStartSec=1200' "$UPGRADE_SERVICE" \
  || fail 'upgrade verifier service timeout is too short'

for marker in debian-installer/exit/poweroff /dev/vda @PASSWORD_HASH@ @BASE_URL@; do
  grep -Fq "$marker" "$PRESEED_TEMPLATE" \
    || fail "preseed template is missing contract marker: $marker"
done

# These patterns intentionally verify literal shell source text.
# shellcheck disable=SC2016
grep -Fq 'SMOKE_RUN_INSTALL_TESTS:-${CI:-false}' "$SMOKE_SCRIPT" \
  || fail 'CI does not enable installed-system tests by default'
grep -Fq 'scripts/installed-system-test.sh' "$SMOKE_SCRIPT" \
  || fail 'smoke harness does not invoke the matrix runner'
if grep -Fq 'for firmware in uefi bios' "$SMOKE_SCRIPT"; then
  fail 'smoke harness still hard-codes firmware cases instead of using the matrix'
fi

for marker in \
  'tests/installed-system/matrix.json' \
  "jq -c '.cases[]'" \
  'runUpgradePath' \
  "INSTALL_TIMEOUT_SECONDS=\"\$install_timeout\"" \
  "INSTALLED_BOOT_TIMEOUT_SECONDS=\"\$boot_timeout\"" \
  'installed-system-evidence.build.json' \
  'installed-system-checksum.build.json' \
  'source_iso_sha' \
  'restore_templates'; do
  grep -Fq "$marker" "$MATRIX_RUNNER" \
    || fail "matrix runner is missing contract marker: $marker"
done

evidence_artifact_name='openclaw-os-0.1.0-amd64.installed-system-evidence.build.json'
case "$evidence_artifact_name" in
  openclaw-os-*.build.json)
    ;;
  *)
    fail 'evidence filename is not included by the verified artifact glob'
    ;;
esac
checksum_artifact_name='openclaw-os-0.1.0-amd64.installed-system-checksum.build.json'
case "$checksum_artifact_name" in
  openclaw-os-*.build.json)
    ;;
  *)
    fail 'checksum filename is not included by the verified artifact glob'
    ;;
esac

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

echo 'Install VM and installed-system matrix harness tests passed.'
