#!/usr/bin/env bash
# platform/nfs-csi/install.sh
# Installiert oder aktualisiert den NFS-CSI-Treiber samt StorageClass "standard".
# Voraussetzungen: NFS-Server (ansible/nfs-server.yml) und nfs-common auf den Knoten (ansible/prepare.yml).
#
#   bash platform/nfs-csi/install.sh
#   NFS_CSI_VERSION=4.13.7 bash platform/nfs-csi/install.sh
set -euo pipefail

NFS_CSI_VERSION="${NFS_CSI_VERSION:-4.13.6}"
NAMESPACE="kube-system"
RELEASE="csi-driver-nfs"
HERE="$(cd "$(dirname "$0")" && pwd)"

for cmd in kubectl helm; do
  command -v "$cmd" >/dev/null || { echo "$cmd fehlt (siehe README, Werkzeuge in WSL)" >&2; exit 1; }
done

echo "Cluster: $(kubectl config current-context)  csi-driver-nfs ${NFS_CSI_VERSION}"
helm repo add csi-driver-nfs https://raw.githubusercontent.com/kubernetes-csi/csi-driver-nfs/master/charts >/dev/null 2>&1 || true
helm repo update csi-driver-nfs >/dev/null

helm upgrade --install "$RELEASE" csi-driver-nfs/csi-driver-nfs \
  --version "$NFS_CSI_VERSION" \
  --namespace "$NAMESPACE" \
  -f "$HERE/values.yaml"

kubectl -n "$NAMESPACE" rollout status deploy/csi-nfs-controller --timeout=5m
kubectl -n "$NAMESPACE" rollout status ds/csi-nfs-node --timeout=5m
kubectl get storageclass
