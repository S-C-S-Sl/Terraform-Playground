#!/usr/bin/env bash
# tools/install-k9s.sh [version]
# Installiert k9s (Terminal-UI für Kubernetes) in WSL/Ubuntu aus den GitHub-Releases,
# mit Prüfung der SHA-256-Prüfsumme.
#
#   bash tools/install-k9s.sh            # neueste Version
#   bash tools/install-k9s.sh v0.51.0    # bestimmte Version
#   K9S_VERSION=v0.51.0 bash tools/install-k9s.sh
set -euo pipefail

REPO="https://github.com/derailed/k9s/releases"
PACKAGE="k9s_linux_amd64.deb"
VERSION="${1:-${K9S_VERSION:-latest}}"

SUDO=""
[[ $EUID -ne 0 ]] && SUDO="sudo"

for cmd in curl sha256sum apt; do
  command -v "$cmd" >/dev/null || { echo "$cmd fehlt" >&2; exit 1; }
done

# "latest" auf die tatsächliche Versionsnummer auflösen (Weiterleitung von GitHub)
if [[ "$VERSION" == "latest" ]]; then
  url="$(curl -fsSLI -o /dev/null -w '%{url_effective}' "$REPO/latest")"
  VERSION="${url##*/}"
fi
[[ "$VERSION" == v* ]] || VERSION="v$VERSION"

# Bereits installiert?
installed="$(k9s version --short 2>/dev/null | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)"
if [[ "$installed" == "$VERSION" ]]; then
  echo "k9s $VERSION ist bereits installiert."
  exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"

echo "Lade k9s $VERSION ..."
curl -fsSLO "$REPO/download/$VERSION/$PACKAGE"
curl -fsSLO "$REPO/download/$VERSION/checksums.sha256"

grep " $PACKAGE\$" checksums.sha256 | sha256sum --check -

$SUDO apt install -y "./$PACKAGE"

echo "Installiert: $(k9s version --short | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -1)${installed:+ (vorher $installed)}"
