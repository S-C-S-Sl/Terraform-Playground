#!/usr/bin/env bash
# platform/registry/ghcr-pull-secret.sh
# Legt im Namespace des Produkts das Pull-Secret "ghcr-pull" für die private Registry ghcr.io an
# (oder aktualisiert es). Das Chart products/shop/chart referenziert es über imagePullSecrets.
# Zugangsdaten gehören nicht ins Repo: Benutzer und Token kommen aus der Umgebung oder werden
# abgefragt. Das Token ist ein GitHub Personal Access Token (classic) mit dem Recht read:packages.
#
#   bash platform/registry/ghcr-pull-secret.sh                 # fragt Benutzer und Token ab
#   GHCR_USER=name GHCR_TOKEN=... bash platform/registry/ghcr-pull-secret.sh
#   NAMESPACE=shop SECRET_NAME=ghcr-pull bash platform/registry/ghcr-pull-secret.sh
set -euo pipefail

NAMESPACE="${NAMESPACE:-shop}"
SECRET_NAME="${SECRET_NAME:-ghcr-pull}"

command -v kubectl >/dev/null || { echo "kubectl fehlt (siehe README, Werkzeuge in WSL)" >&2; exit 1; }

if [ -z "${GHCR_USER:-}" ]; then read -rp "GitHub-Benutzer für ghcr.io: " GHCR_USER; fi
if [ -z "${GHCR_TOKEN:-}" ]; then read -rsp "Token (read:packages): " GHCR_TOKEN; echo; fi
[ -n "$GHCR_USER" ] && [ -n "$GHCR_TOKEN" ] || { echo "Benutzer und Token werden benötigt" >&2; exit 1; }

# Namespace gehört dem Produkt; hier nur sicherstellen, dass er existiert
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

# Secret als YAML über die Standardeingabe: das Token steht nie in einer Prozessliste
auth="$(printf '%s:%s' "$GHCR_USER" "$GHCR_TOKEN" | base64 -w0)"
dockerconfig="$(printf '{"auths":{"ghcr.io":{"username":"%s","password":"%s","auth":"%s"}}}' \
  "$GHCR_USER" "$GHCR_TOKEN" "$auth" | base64 -w0)"
kubectl apply -f - >/dev/null <<YAML
apiVersion: v1
kind: Secret
metadata:
  name: ${SECRET_NAME}
  namespace: ${NAMESPACE}
type: kubernetes.io/dockerconfigjson
data:
  .dockerconfigjson: ${dockerconfig}
YAML

echo "Secret $NAMESPACE/$SECRET_NAME für ghcr.io ist angelegt."
