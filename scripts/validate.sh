#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAILURES=0

fail() {
  echo "ERROR: $*" >&2
  FAILURES=$((FAILURES + 1))
}

note() {
  echo "[validate] $*"
}

note "checking required files"
required_files=(
  VERSION
  README.md
  SECURITY.md
  image/auto/config
  image/config/package-lists/openclaw-os.list.chroot
  image/config/hooks/normal/0100-install-runtime.hook.chroot
  image/config/hooks/normal/0200-configure-appliance.hook.chroot
  image/config/hooks/normal/0980-generate-sbom.hook.chroot
  image/config/includes.chroot/usr/local/sbin/openclaw-appliance
  image/config/includes.chroot/usr/local/sbin/openclaw-console
  image/config/includes.chroot/etc/systemd/system/openclaw.service
  image/config/includes.chroot/etc/systemd/system/openclaw-podman.service
  image/config/includes.chroot/etc/systemd/system/openclaw-boot-marker.service
  image/config/includes.chroot/usr/share/openclaw-os/release.env
  scripts/verify-artifacts.sh
  scripts/smoke-iso.sh
  tests/appliance-test.sh
)
for relative_path in "${required_files[@]}"; do
  [[ -f "$ROOT_DIR/$relative_path" ]] || fail "missing $relative_path"
done

note "checking shell syntax"
while IFS= read -r -d '' script; do
  if ! bash -n "$script"; then
    fail "bash syntax failed: ${script#"$ROOT_DIR/"}"
  fi
done < <(find "$ROOT_DIR" -type f \( \
  -name '*.sh' \
  -o -path '*/auto/config' \
  -o -path '*/auto/clean' \
  -o -path '*/hooks/normal/*.hook.chroot' \
  -o -path '*/usr/local/bin/*' \
  -o -path '*/usr/local/sbin/*' \
  -o -path '*/usr/libexec/openclaw-appliance/*' \
  \) -print0)

if command -v shellcheck >/dev/null 2>&1; then
  note "running shellcheck"
  mapfile -d '' shell_files < <(find \
    "$ROOT_DIR/scripts" \
    "$ROOT_DIR/tests" \
    "$ROOT_DIR/image/auto" \
    "$ROOT_DIR/image/config/hooks" \
    "$ROOT_DIR/image/config/includes.chroot/usr/local/bin" \
    "$ROOT_DIR/image/config/includes.chroot/usr/local/sbin" \
    "$ROOT_DIR/image/config/includes.chroot/usr/libexec/openclaw-appliance" \
    -type f -print0)
  if ! shellcheck -x -e SC1091,SC2154,SC2317,SC2329 "${shell_files[@]}"; then
    fail "shellcheck reported errors"
  fi
else
  note "shellcheck not installed, syntax checks only"
fi

note "checking release pins"
# shellcheck disable=SC1091
source "$ROOT_DIR/image/config/includes.chroot/usr/share/openclaw-os/release.env"
[[ "$OPENCLAW_OS_VERSION" == "$(<"$ROOT_DIR/VERSION")" ]] || fail "VERSION and release.env disagree"
[[ "$DEBIAN_CODENAME" == "trixie" ]] || fail "Debian release must remain trixie for 0.1.0"
[[ "$NODE_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "invalid NODE_VERSION"
[[ "$OPENCLAW_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9.-]+)?$ ]] || fail "invalid OPENCLAW_VERSION"
[[ "$NODE_SHA256_AMD64" =~ ^[a-f0-9]{64}$ ]] || fail "invalid amd64 Node SHA-256"
[[ "$NODE_SHA256_ARM64" =~ ^[a-f0-9]{64}$ ]] || fail "invalid arm64 Node SHA-256"
[[ "$OPENCLAW_NPM_INTEGRITY" =~ ^sha512-[A-Za-z0-9+/=]+$ ]] || fail "invalid OpenClaw SRI"
[[ "$OPENCLAW_TARBALL_URL" == "https://registry.npmjs.org/openclaw/-/openclaw-${OPENCLAW_VERSION}.tgz" ]] || fail "unexpected OpenClaw tarball URL"
[[ "$OPENCLAW_RELEASE_COMMIT" =~ ^[a-f0-9]{40}$ ]] || fail "invalid OpenClaw release commit"

note "checking OpenClaw appliance policy"
default_patch="$ROOT_DIR/image/config/includes.chroot/usr/share/openclaw-os/defaults/openclaw.patch.json5"
grep -q 'checkOnStart: false' "$default_patch" || fail "OpenClaw startup update checks must be disabled"
grep -A3 'auto:' "$default_patch" | grep -q 'enabled: false' || fail "OpenClaw background auto-update must be disabled"
grep -q 'mode: "all"' "$default_patch" || fail "sandboxing must default to all sessions"
grep -q 'network: "none"' "$default_patch" || fail "sandbox network must default to none"
grep -q 'enabled: false' "$default_patch" || fail "elevated tools must default to disabled"

note "checking systemd hardening and ownership"
unit="$ROOT_DIR/image/config/includes.chroot/etc/systemd/system/openclaw.service"
grep -q '^User=openclaw$' "$unit" || fail "Gateway service must use openclaw user"
grep -q '^NoNewPrivileges=yes$' "$unit" || fail "Gateway service must set NoNewPrivileges"
grep -q '^RestartPreventExitStatus=78$' "$unit" || fail "Gateway service must stop retrying configuration failures"
grep -q '^ProtectSystem=strict$' "$unit" || fail "Gateway service must protect the system tree"
grep -q '^CapabilityBoundingSet=$' "$unit" || fail "Gateway service must drop capabilities"
grep -q 'ConditionPathExists=/var/lib/openclaw/state/openclaw.json' "$unit" || fail "Gateway must not start before onboarding"
podman_unit="$ROOT_DIR/image/config/includes.chroot/etc/systemd/system/openclaw-podman.service"
grep -q '^User=openclaw$' "$podman_unit" || fail "Podman service must use openclaw user"
grep -q '^Delegate=yes$' "$podman_unit" || fail "Podman service must receive delegated cgroups"
grep -q 'AF_PACKET' "$podman_unit" || fail "Podman service needs AF_PACKET for container networking"
console_unit="$ROOT_DIR/image/config/includes.chroot/etc/systemd/system/openclaw-console.service"
grep -q '^Before=getty@tty1.service$' "$console_unit" || fail "appliance console must start before tty1 getty"
configure_hook="$ROOT_DIR/image/config/hooks/normal/0200-configure-appliance.hook.chroot"
grep -q 'systemctl enable openclaw-boot-marker.service' "$configure_hook" || fail "boot marker service is not enabled"
grep -q 'systemctl mask ssh.service ssh.socket' "$configure_hook" || fail "SSH must be masked in the image"

note "checking pinned container bases"
containerfile="$ROOT_DIR/image/config/includes.chroot/usr/share/openclaw-os/sandbox/Containerfile"
grep -Eq '^FROM .+@sha256:[a-f0-9]{64}$' "$containerfile" || fail "sandbox base image is not digest pinned"
build_workflow="$ROOT_DIR/.github/workflows/build-iso.yml"
grep -Eq 'DEBIAN_BUILD_IMAGE: debian:13-slim@sha256:[a-f0-9]{64}$' "$build_workflow" || fail "CI Debian build image is not digest pinned"

note "checking GitHub Actions pins"
while IFS= read -r action_line; do
  [[ "$action_line" =~ uses:[[:space:]]+[^@[:space:]]+@[a-f0-9]{40}([[:space:]]|$) ]] || fail "GitHub Action is not pinned by full commit SHA: $action_line"
done < <(grep -RhoE '^[[:space:]]*uses:[[:space:]]+[^[:space:]]+' "$ROOT_DIR/.github/workflows" || true)

note "checking package profile"
package_list="$ROOT_DIR/image/config/package-lists/openclaw-os.list.chroot"
if grep -q '^debian-installer-launcher$' "$package_list"; then
  fail "desktop Debian installer launcher must not be included"
fi

note "checking repository for credential-shaped literals"
if grep -RInE \
  --exclude-dir=.git \
  --exclude='validate.sh' \
  '(sk-[A-Za-z0-9_-]{20,}|ghp_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{20,}|AKIA[0-9A-Z]{16}|-----BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY-----)' \
  "$ROOT_DIR"; then
  fail "credential-shaped literal found"
fi

note "checking executable bits"
while IFS= read -r -d '' executable; do
  [[ -x "$executable" ]] || fail "not executable: ${executable#"$ROOT_DIR/"}"
done < <(find \
  "$ROOT_DIR/scripts" \
  "$ROOT_DIR/tests" \
  "$ROOT_DIR/image/auto" \
  "$ROOT_DIR/image/config/hooks" \
  "$ROOT_DIR/image/config/includes.chroot/usr/local/bin" \
  "$ROOT_DIR/image/config/includes.chroot/usr/local/sbin" \
  "$ROOT_DIR/image/config/includes.chroot/usr/libexec/openclaw-appliance" \
  -type f -print0)

note "running appliance unit tests"
if ! "$ROOT_DIR/tests/appliance-test.sh"; then
  fail "appliance unit tests failed"
fi

note "testing firewall grammar"
test_root="$(mktemp -d)"
trap 'rm -rf "$test_root"' EXIT
mkdir -p "$test_root/etc/openclaw"
printf '22\n' >"$test_root/etc/openclaw/allowed-tcp-ports"
printf '18789\n' >"$test_root/etc/openclaw/allowed-lan-tcp-ports"
if ! OPENCLAW_ROOT="$test_root" \
  OPENCLAW_LIB="$ROOT_DIR/image/config/includes.chroot/usr/libexec/openclaw-appliance/lib.sh" \
  "$ROOT_DIR/image/config/includes.chroot/usr/local/sbin/openclaw-appliance" firewall render --no-apply; then
  fail "firewall renderer failed"
elif ! grep -q 'elements = { 22 }' "$test_root/etc/nftables.conf" || ! grep -q 'elements = { 18789 }' "$test_root/etc/nftables.conf"; then
  fail "firewall renderer did not persist allowed ports"
elif command -v nft >/dev/null 2>&1 && [[ "$EUID" -eq 0 ]]; then
  if ! nft --check --file "$test_root/etc/nftables.conf"; then
    fail "nftables rejected the rendered ruleset"
  fi
fi

if [[ "$FAILURES" -ne 0 ]]; then
  echo "Validation failed with $FAILURES error(s)." >&2
  exit 1
fi

echo "Validation passed."
