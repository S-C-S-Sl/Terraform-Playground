#!/usr/bin/env bash
# tools/install-helm.sh
# Installiert Helm in WSL/Ubuntu aus dem offiziellen apt-Repository des Helm-Projekts.
# Wiederholbar: bindet das Repository (neu) ein und installiert bzw. aktualisiert Helm.
#
#   bash tools/install-helm.sh
set -euo pipefail

KEY_URL="https://packages.buildkite.com/helm-linux/helm-debian/gpgkey"
REPO_LINE="deb [signed-by=/usr/share/keyrings/helm.gpg] https://packages.buildkite.com/helm-linux/helm-debian/any/ any main"
KEYRING="/usr/share/keyrings/helm.gpg"
SOURCES="/etc/apt/sources.list.d/helm-stable-debian.list"

SUDO=""
[[ $EUID -ne 0 ]] && SUDO="sudo"

before="$(helm version --short 2>/dev/null || true)"

$SUDO apt-get update -qq
$SUDO apt-get install -y -qq curl gpg apt-transport-https >/dev/null

echo "Binde das Helm-Repository ein ..."
curl -fsSL "$KEY_URL" | gpg --dearmor | $SUDO tee "$KEYRING" > /dev/null
echo "$REPO_LINE" | $SUDO tee "$SOURCES" > /dev/null

$SUDO apt-get update -qq
$SUDO apt-get install -y helm

after="$(helm version --short)"
if [[ -n "$before" && "$before" != "$after" ]]; then
  echo "Helm aktualisiert: $before -> $after"
else
  echo "Helm: $after"
fi
