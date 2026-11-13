#!/usr/bin/env bash
# scripts/prepare-image.sh <name> <quelle> [zielverzeichnis]
#
# Beispiele:
#   bash scripts/prepare-image.sh ubuntu-2404 https://cloud-images.ubuntu.com/releases/noble/release-20261017/ubuntu-24.04-server-cloudimg-amd64.img
#   bash scripts/prepare-image.sh rhel-9 ~/Downloads/rhel-9.x-x86_64-kvm.qcow2
set -euo pipefail

if [[ $# -lt 2 ]]; then
  echo "Aufruf: $0 <name> <url-oder-datei> [zielverzeichnis]" >&2
  exit 1
fi

NAME="$1"
SOURCE="$2"
TARGET_DIR="${3:-/mnt/d/Hyper-V/images}"
TARGET="${TARGET_DIR}/${NAME}-base.vhdx"
DISK_SIZE="${DISK_SIZE:-20G}"

command -v qemu-img >/dev/null || { echo "qemu-img fehlt: sudo apt install -y qemu-utils" >&2; exit 1; }
command -v curl     >/dev/null || { echo "curl fehlt: sudo apt install -y curl" >&2; exit 1; }

if [[ -e "$TARGET" ]]; then
  echo "Ziel existiert bereits: $TARGET (Basis-Images werden nicht überschrieben)" >&2
  exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
IMG="$WORK/source.qcow2"

if [[ "$SOURCE" =~ ^https?:// ]]; then
  FILE="${SOURCE##*/}"
  echo "Lade $FILE ..."
  curl -fL --progress-bar -o "$IMG" "$SOURCE"

  if curl -fsSL -o "$WORK/SHA256SUMS" "${SOURCE%/*}/SHA256SUMS"; then
    EXPECTED="$(grep -E " \*?${FILE}\$" "$WORK/SHA256SUMS" | cut -d' ' -f1 || true)"
    if [[ -z "$EXPECTED" ]]; then
      echo "Keine Prüfsumme für $FILE in SHA256SUMS gefunden" >&2
      exit 1
    fi
    echo "${EXPECTED}  $IMG" | sha256sum -c -
  else
    echo "WARNUNG: keine SHA256SUMS gefunden, Prüfsumme nicht verifiziert" >&2
  fi
else
  [[ -f "$SOURCE" ]] || { echo "Datei nicht gefunden: $SOURCE" >&2; exit 1; }
  cp "$SOURCE" "$IMG"
fi

echo "Vergrößere virtuelle Disk auf $DISK_SIZE ..."
qemu-img resize -f qcow2 "$IMG" "$DISK_SIZE"

echo "Konvertiere nach VHDX ..."
# Im Linux-Dateisystem konvertieren; direkt auf /mnt/<laufwerk> schlägt qemu-img fehl
qemu-img convert -p -f qcow2 -O vhdx -o subformat=dynamic "$IMG" "$WORK/out.vhdx"

echo "Kopiere nach $TARGET ..."
mkdir -p "$TARGET_DIR"
cp "$WORK/out.vhdx" "$TARGET"

echo "Basis-Image: $TARGET"
