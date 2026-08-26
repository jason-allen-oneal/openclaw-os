#!/usr/bin/env bash
set -Eeuo pipefail

ARCH="${1:-amd64}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE_DIR="$ROOT_DIR/image"
DIST_DIR="$ROOT_DIR/dist"
VERSION="$(<"$ROOT_DIR/VERSION")"
LOG_FILE="$DIST_DIR/build-${VERSION}-${ARCH}.log"
CONTROL_PLANE_DESTINATION="$IMAGE_DIR/config/includes.chroot/usr/lib/openclaw-os/control-plane"
extract_dir=""

cleanup() {
  rm -rf "$CONTROL_PLANE_DESTINATION"
  if [[ -n "$extract_dir" ]]; then
    rm -rf "$extract_dir"
  fi
}
trap cleanup EXIT

# shellcheck disable=SC1091
source "$ROOT_DIR/image/config/includes.chroot/usr/share/openclaw-os/release.env"

if [[ "$EUID" -ne 0 ]]; then
  echo "build-image.sh must run as root. Use: sudo $0 $ARCH" >&2
  exit 1
fi

if [[ "$ARCH" != "amd64" ]]; then
  echo "OpenClaw OS $VERSION currently builds amd64 installer media only." >&2
  exit 1
fi

required=(lb debootstrap xorriso mksquashfs unsquashfs grub-mkimage isohybrid curl jq sha256sum)
missing=()
for command_name in "${required[@]}"; do
  command -v "$command_name" >/dev/null 2>&1 || missing+=("$command_name")
done
if ((${#missing[@]} > 0)); then
  printf 'Missing build commands: %s\n' "${missing[*]}" >&2
  exit 1
fi

mkdir -p "$DIST_DIR"
rm -f "$LOG_FILE"

export ARCHITECTURE="$ARCH"
export OPENCLAW_OS_VERSION="$VERSION"
if git -C "$ROOT_DIR" rev-parse --verify HEAD >/dev/null 2>&1; then
  SOURCE_DATE_EPOCH="$(git -C "$ROOT_DIR" show -s --format=%ct HEAD)"
  export SOURCE_DATE_EPOCH
fi

cd "$IMAGE_DIR"
lb clean --purge >/dev/null 2>&1 || true
find . -maxdepth 1 -type f -name '*.iso' -delete
"$ROOT_DIR/scripts/stage-control-plane.sh" "$CONTROL_PLANE_DESTINATION"
./auto/config

set +e
lb build 2>&1 | tee "$LOG_FILE"
build_status=${PIPESTATUS[0]}
set -e
if [[ "$build_status" -ne 0 ]]; then
  echo "live-build failed. See $LOG_FILE" >&2
  exit "$build_status"
fi

source_iso=""
for candidate in \
  "openclaw-os-${ARCH}.hybrid.iso" \
  "openclaw-os-${ARCH}.iso" \
  "openclaw-os-${ARCH}-${ARCH}.hybrid.iso" \
  "live-image-${ARCH}.hybrid.iso" \
  "live-image-${ARCH}.iso"; do
  if [[ -f "$candidate" ]]; then
    source_iso="$candidate"
    break
  fi
done

if [[ -z "$source_iso" ]]; then
  mapfile -t generated_isos < <(find . -maxdepth 1 -type f -name '*.iso' -printf '%f\n' | sort)
  if ((${#generated_isos[@]} == 1)); then
    source_iso="${generated_isos[0]}"
  elif ((${#generated_isos[@]} > 1)); then
    printf 'live-build produced multiple unrecognized ISO files:\n' >&2
    printf '  %s\n' "${generated_isos[@]}" >&2
    exit 1
  else
    echo "live-build completed but no ISO was found in $IMAGE_DIR" >&2
    exit 1
  fi
fi

target_iso="$DIST_DIR/openclaw-os-${VERSION}-${ARCH}.iso"
install -m 0644 "$source_iso" "$target_iso"
(
  cd "$DIST_DIR"
  sha256sum "$(basename "$target_iso")" >"$(basename "$target_iso").sha256"
)

sbom_target="$DIST_DIR/openclaw-os-${VERSION}-${ARCH}.sbom.spdx.json"
extract_dir="$(mktemp -d)"
xorriso -osirrox on -indev "$target_iso" \
  -extract /live/filesystem.squashfs "$extract_dir/filesystem.squashfs" \
  >/dev/null 2>&1
unsquashfs -cat "$extract_dir/filesystem.squashfs" \
  usr/share/openclaw-os/sbom.spdx.json >"$sbom_target"
jq -e '
  .spdxVersion == "SPDX-2.3"
  and (.packages | any(.SPDXID == "SPDXRef-OpenClawOSControlPlane"))
  and ([.packages[] | select(.SPDXID | startswith("SPDXRef-NpmPackage-"))] | length > 0)
' "$sbom_target" >/dev/null
(
  cd "$DIST_DIR"
  sha256sum "$(basename "$sbom_target")" >"$(basename "$sbom_target").sha256"
)

control_plane_version="$(jq -er '.version' "$ROOT_DIR/package.json")"
cat >"$DIST_DIR/openclaw-os-${VERSION}-${ARCH}.build.json" <<JSON
{
  "openclawOsVersion": "$VERSION",
  "controlPlaneVersion": "$control_plane_version",
  "architecture": "$ARCH",
  "debianCodename": "$DEBIAN_CODENAME",
  "nodeVersion": "$NODE_VERSION",
  "openclawVersion": "$OPENCLAW_VERSION",
  "openclawReleaseCommit": "$OPENCLAW_RELEASE_COMMIT",
  "gitCommit": "$(git -C "$ROOT_DIR" rev-parse HEAD 2>/dev/null || printf unknown)",
  "builtAt": "$(date --utc +%Y-%m-%dT%H:%M:%SZ)"
}
JSON

printf 'Built: %s\n' "$target_iso"
printf 'SHA-256: %s\n' "$(cut -d' ' -f1 "$target_iso.sha256")"
printf 'SBOM: %s\n' "$sbom_target"
