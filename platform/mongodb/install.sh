#!/usr/bin/env bash
# platform/mongodb/install.sh
# Installiert oder aktualisiert MongoDB (eigenes Helm-Chart). Setzt die StorageClass "standard"
# voraus (platform/nfs-csi). MongoDB läuft im eigenen Namespace "mongodb"; die Zugangsdaten der
# Dienste legt das Chart als Secrets in deren Namespaces an (values.yaml, clients).
#
#   bash platform/mongodb/install.sh
set -euo pipefail

RELEASE="${RELEASE:-mongodb}"
NAMESPACE="${NAMESPACE:-mongodb}"
HERE="$(cd "$(dirname "$0")" && pwd)"

for cmd in kubectl helm; do
  command -v "$cmd" >/dev/null || { echo "$cmd fehlt (siehe README, Werkzeuge in WSL)" >&2; exit 1; }
done

echo "Cluster: $(kubectl config current-context)  Namespace: $NAMESPACE"
if ! kubectl get storageclass standard >/dev/null 2>&1; then
  echo "StorageClass standard fehlt. Zuerst: ansible/nfs-server.yml und bash platform/nfs-csi/install.sh" >&2
  exit 1
fi

helm lint "$HERE/chart"

# Namespaces der Dienste müssen existieren, damit Helm dort die Client-Secrets anlegen kann.
# Sie gehören den Produkten, nicht diesem Release - deshalb hier per kubectl statt im Chart.
for ns in $(helm template "$RELEASE" "$HERE/chart" -n "$NAMESPACE" "$@" --show-only templates/client-secrets.yaml \
            | awk '/^  namespace:/ {print $2}' | sort -u); do
  kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  echo "Namespace vorhanden: $ns"
done

# --wait: Helm wartet, bis der Pod bereit ist, bevor der Init-Job (Hook) läuft
helm upgrade --install "$RELEASE" "$HERE/chart" \
  --namespace "$NAMESPACE" --create-namespace \
  --wait --timeout 10m \
  "$@"

kubectl -n "$NAMESPACE" get statefulset,pod,pvc,svc -l app.kubernetes.io/instance="$RELEASE"
kubectl get secret -A -l app.kubernetes.io/component=client-credentials,app.kubernetes.io/instance="$RELEASE"
