#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

export OPENCLAW_APPLIANCE_LIBRARY_ONLY=1
export OPENCLAW_ROOT="$TEST_ROOT/root"
export OPENCLAW_RELEASES_DIR="$TEST_ROOT/releases"
export OPENCLAW_CURRENT_LINK="$TEST_ROOT/current"
export OPENCLAW_CONFIG_FILE="$TEST_ROOT/config/openclaw.json"
export APPLIANCE_CONFIG_FILE="$TEST_ROOT/appliance.conf"
export OPENCLAW_LIB="$ROOT_DIR/image/config/includes.chroot/usr/libexec/openclaw-appliance/lib.sh"

# shellcheck disable=SC1090
source "$ROOT_DIR/image/config/includes.chroot/usr/local/sbin/openclaw-appliance"

metadata='{
  "version": "2026.6.34",
  "dist": {
    "integrity": "sha512-VGVzdA==",
    "tarball": "https://registry.npmjs.org/openclaw/-/openclaw-2026.6.34.tgz",
    "signatures": [{"keyid":"SHA256:test","sig":"test"}]
  }
}'
parse_npm_metadata "$metadata"
[[ "$RESOLVED_VERSION" == "2026.6.34" ]] || die "Metadata parser returned the wrong version"
[[ "$RESOLVED_SIGNATURE_COUNT" == "1" ]] || die "Metadata parser did not count signatures"

unsigned_metadata='{
  "version": "2026.6.34",
  "dist": {
    "integrity": "sha512-VGVzdA==",
    "tarball": "https://registry.npmjs.org/openclaw/-/openclaw-2026.6.34.tgz"
  }
}'
if (parse_npm_metadata "$unsigned_metadata") >/dev/null 2>&1; then
  die "Unsigned package metadata was accepted"
fi

printf test >"$TEST_ROOT/sri-input"
expected_sri="sha512-$(openssl dgst -sha512 -binary "$TEST_ROOT/sri-input" | openssl base64 -A)"
verify_sri "$TEST_ROOT/sri-input" "$expected_sri"
if (verify_sri "$TEST_ROOT/sri-input" 'sha512-V3Jvbmc=') >/dev/null 2>&1; then
  die "Incorrect SRI was accepted"
fi

# shellcheck disable=SC2016
release_body='- npm integrity: `sha512-VGVzdA==`
- Release commit: [`0123456789abcdef0123456789abcdef01234567`](https://example.invalid)'
[[ "$(extract_release_integrity <<<"$release_body")" == "sha512-VGVzdA==" ]] || die "Release SRI extraction failed"
[[ "$(extract_release_commit <<<"$release_body")" == "0123456789abcdef0123456789abcdef01234567" ]] || die "Release commit extraction failed"

cat >"$TEST_ROOT/release.json" <<'JSON'
{
  "tag_name": "v2026.6.34",
  "draft": false,
  "prerelease": false,
  "published_at": "2026-08-08T07:22:14Z",
  "body": "- npm integrity: `sha512-VGVzdA==`\n- Release commit: [`0123456789abcdef0123456789abcdef01234567`](https://example.invalid)"
}
JSON
cat >"$TEST_ROOT/registry.json" <<'JSON'
{
  "version": "2026.6.34",
  "dist": {
    "integrity": "sha512-VGVzdA==",
    "tarball": "https://registry.npmjs.org/openclaw/-/openclaw-2026.6.34.tgz",
    "signatures": [{"keyid":"SHA256:test","sig":"test"}]
  }
}
JSON
download_https() {
  local url="$1"
  local destination="$2"
  case "$url" in
    https://registry.npmjs.org/openclaw/*) cp "$TEST_ROOT/registry.json" "$destination" ;;
    https://api.github.com/repos/openclaw/openclaw/releases/tags/*) cp "$TEST_ROOT/release.json" "$destination" ;;
    *) die "Unexpected test download URL: $url" ;;
  esac
}
resolve_npm_metadata extended-stable
[[ "$RESOLVED_VERSION" == "2026.6.34" ]] || die "Resolved registry version was incorrect"
verify_openclaw_release_metadata \
  2026.6.34 \
  sha512-VGVzdA== \
  0123456789abcdef0123456789abcdef01234567
if (verify_openclaw_release_metadata 2026.6.34 sha512-V3Jvbmc=) >/dev/null 2>&1; then
  die "Mismatched GitHub and npm integrity was accepted"
fi

mkdir -p "$OPENCLAW_RELEASES_DIR" "$OPENCLAW_ROOT/etc/openclaw"
for version in 1.0.0 2.0.0 3.0.0 4.0.0; do
  mkdir -p "$OPENCLAW_RELEASES_DIR/$version/bin"
  touch "$OPENCLAW_RELEASES_DIR/$version/bin/openclaw"
done
touch -d '2026-01-01' "$OPENCLAW_RELEASES_DIR/1.0.0"
touch -d '2026-02-01' "$OPENCLAW_RELEASES_DIR/2.0.0"
touch -d '2026-03-01' "$OPENCLAW_RELEASES_DIR/3.0.0"
touch -d '2026-04-01' "$OPENCLAW_RELEASES_DIR/4.0.0"
ln -s "$OPENCLAW_RELEASES_DIR/3.0.0" "$OPENCLAW_CURRENT_LINK"
printf 'KEEP_OPENCLAW_RELEASES=3\n' >"$APPLIANCE_CONFIG_FILE"
prune_releases
[[ ! -d "$OPENCLAW_RELEASES_DIR/1.0.0" ]] || die "Old release was not pruned"
[[ -d "$OPENCLAW_RELEASES_DIR/2.0.0" ]] || die "Newest inactive fallback was pruned"
[[ -d "$OPENCLAW_RELEASES_DIR/3.0.0" ]] || die "Active release was pruned"
[[ -d "$OPENCLAW_RELEASES_DIR/4.0.0" ]] || die "Newest release was pruned"

printf '22\n' >"$OPENCLAW_ROOT/etc/openclaw/allowed-tcp-ports"
printf '18789\n' >"$OPENCLAW_ROOT/etc/openclaw/allowed-lan-tcp-ports"
firewall_render --no-apply
grep -q 'elements = { 22 }' "$OPENCLAW_ROOT/etc/nftables.conf" || die "Firewall renderer lost global ports"
grep -q 'elements = { 18789 }' "$OPENCLAW_ROOT/etc/nftables.conf" || die "Firewall renderer lost LAN ports"
grep -q 'policy drop;' "$OPENCLAW_ROOT/etc/nftables.conf" || die "Firewall renderer lost the drop policy"

# A failed candidate validation must restore the previous code and restart it.
mkdir -p "$(dirname "$OPENCLAW_CONFIG_FILE")" "$OPENCLAW_RELEASES_DIR/5.0.0/bin"
printf '{}\n' >"$OPENCLAW_CONFIG_FILE"
touch "$OPENCLAW_RELEASES_DIR/5.0.0/bin/openclaw"
chmod +x "$OPENCLAW_RELEASES_DIR/5.0.0/bin/openclaw"
previous_target="$(readlink -f "$OPENCLAW_CURRENT_LINK")"
systemctl_log="$TEST_ROOT/systemctl.log"
run_openclaw() { return 1; }
systemctl() {
  printf '%s\n' "$*" >>"$systemctl_log"
  return 0
}
wait_for_gateway_health() { return 0; }
if activate_release "$OPENCLAW_RELEASES_DIR/5.0.0" "$previous_target"; then
  die "Invalid candidate release was activated"
fi
[[ "$(readlink -f "$OPENCLAW_CURRENT_LINK")" == "$previous_target" ]] || \
  die "Invalid candidate did not restore the previous release"
grep -q '^restart openclaw.service$' "$systemctl_log" || \
  die "Previous Gateway was not restarted after candidate validation failure"

echo "Appliance tests passed."
