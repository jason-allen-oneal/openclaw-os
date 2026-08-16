#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEFAULT_DESTINATION="$ROOT_DIR/image/config/includes.chroot/usr/lib/openclaw-os/control-plane"
DESTINATION="${1:-$DEFAULT_DESTINATION}"

case "$DESTINATION" in
  /*) ;;
  *)
    echo "stage destination must be an absolute path" >&2
    exit 1
    ;;
esac

source_paths=(
  "$ROOT_DIR/package.json"
  "$ROOT_DIR/config"
  "$ROOT_DIR/packages"
  "$ROOT_DIR/services"
)
for source_path in "${source_paths[@]}"; do
  [[ -e "$source_path" ]] || {
    echo "missing control-plane source: $source_path" >&2
    exit 1
  }
done

if find "${source_paths[@]}" -type l -print -quit | grep -q .; then
  echo "control-plane source must not contain symbolic links" >&2
  exit 1
fi

rm -rf -- "$DESTINATION"
install -d -m 0755 "$DESTINATION"
install -m 0644 "$ROOT_DIR/package.json" "$DESTINATION/package.json"
cp -R --no-preserve=ownership "$ROOT_DIR/config" "$DESTINATION/config"
cp -R --no-preserve=ownership "$ROOT_DIR/packages" "$DESTINATION/packages"
cp -R --no-preserve=ownership "$ROOT_DIR/services" "$DESTINATION/services"
find "$DESTINATION" -type d -exec chmod 0755 {} +
find "$DESTINATION" -type f -exec chmod 0644 {} +

printf 'Staged OpenClaw OS control plane at %s\n' "$DESTINATION"
