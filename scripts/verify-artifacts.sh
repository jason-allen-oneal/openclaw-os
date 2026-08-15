#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARCH="${1:-amd64}"

# shellcheck disable=SC1091
source "$ROOT_DIR/image/config/includes.chroot/usr/share/openclaw-os/release.env"
# shellcheck disable=SC1091
source "$ROOT_DIR/image/config/includes.chroot/usr/libexec/openclaw-appliance/lib.sh"

case "$ARCH" in
  amd64)
    node_arch=x64
    node_sha256="$NODE_SHA256_AMD64"
    ;;
  arm64)
    node_arch=arm64
    node_sha256="$NODE_SHA256_ARM64"
    ;;
  *)
    die "Unsupported verification architecture: $ARCH"
    ;;
esac

work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

node_archive="node-v${NODE_VERSION}-linux-${node_arch}.tar.xz"
node_path="$work_dir/$node_archive"
openclaw_path="$work_dir/openclaw-${OPENCLAW_VERSION}.tgz"
metadata_path="$work_dir/openclaw-metadata.json"

log "Verifying Node.js $NODE_VERSION for $ARCH"
download_https "https://nodejs.org/dist/v${NODE_VERSION}/${node_archive}" "$node_path"
printf '%s  %s\n' "$node_sha256" "$node_path" | sha256sum --check --status

tar -xJf "$node_path" -C "$work_dir" "node-v${NODE_VERSION}-linux-${node_arch}/bin/node"
if [[ "$ARCH" == "amd64" && "$(uname -m)" == "x86_64" ]]; then
  actual_node="$($work_dir/node-v${NODE_VERSION}-linux-${node_arch}/bin/node --version)"
  [[ "$actual_node" == "v$NODE_VERSION" ]] || die "Node archive reported $actual_node"
fi

log "Verifying OpenClaw $OPENCLAW_VERSION registry metadata"
download_https "https://registry.npmjs.org/openclaw/${OPENCLAW_VERSION}" "$metadata_path"
parse_npm_metadata "$(cat "$metadata_path")"
[[ "$RESOLVED_VERSION" == "$OPENCLAW_VERSION" ]] || die "Pinned OpenClaw version does not match registry metadata"
[[ "$RESOLVED_INTEGRITY" == "$OPENCLAW_NPM_INTEGRITY" ]] || die "Pinned OpenClaw SRI does not match registry metadata"
[[ "$RESOLVED_TARBALL" == "$OPENCLAW_TARBALL_URL" ]] || die "Pinned OpenClaw tarball does not match registry metadata"
verify_openclaw_release_metadata "$OPENCLAW_VERSION" "$OPENCLAW_NPM_INTEGRITY" "$OPENCLAW_RELEASE_COMMIT"

log "Verifying OpenClaw $OPENCLAW_VERSION package archive"
download_https "$OPENCLAW_TARBALL_URL" "$openclaw_path"
verify_sri "$openclaw_path" "$OPENCLAW_NPM_INTEGRITY"
archive_version="$(tar -xOf "$openclaw_path" package/package.json | jq -r '.version // empty')"
[[ "$archive_version" == "$OPENCLAW_VERSION" ]] || die "OpenClaw archive reported version $archive_version"

cat <<SUMMARY
Verified artifact set:
  Node.js:  $NODE_VERSION ($ARCH)
  OpenClaw: $OPENCLAW_VERSION
  Release:  $OPENCLAW_RELEASE_COMMIT
SUMMARY
