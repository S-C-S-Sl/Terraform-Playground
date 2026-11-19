#!/usr/bin/env bash
# platform/mongodb/install.sh
# Installiert oder aktualisiert MongoDB (eigenes Helm-Chart). Setzt die StorageClass "standard"
# voraus (platform/nfs-csi). Standard-Namespace ist der der Anwendungen ("demo"),
# weil diese das Secret mit dem Connection-String nur im eigenen Namespace lesen können.
#
#   bash platform/mongodb/install.sh
set -euo pipefail

RELEASE="${RELEASE:-mongodb}"
NAMESPACE="${NAMESPACE:-demo}"
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
# --wait: Helm wartet, bis der Pod bereit ist, bevor der Init-Job (Hook) läuft
helm upgrade --install "$RELEASE" "$HERE/chart" \
  --namespace "$NAMESPACE" --create-namespace \
  --wait --timeout 10m \
  "$@"

kubectl -n "$NAMESPACE" get statefulset,pod,pvc,svc -l app.kubernetes.io/instance="$RELEASE"
