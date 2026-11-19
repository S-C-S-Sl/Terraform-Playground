#!/usr/bin/env bash
# platform/envoy-gateway/install.sh
# Installiert oder aktualisiert Envoy Gateway (Gateway-API-Controller) im Cluster
# der aktuellen kubeconfig. Die Chart bringt die Gateway-API-CRDs mit.
#
#   bash platform/envoy-gateway/install.sh
#   EG_VERSION=v1.10.1 bash platform/envoy-gateway/install.sh
set -euo pipefail

# v1.10: getestet mit Kubernetes 1.34-1.37 und Gateway API v1.6.1 (Kompatibilitätsmatrix)
EG_VERSION="${EG_VERSION:-v1.10.0}"
NAMESPACE="envoy-gateway-system"
RELEASE="eg"
HERE="$(cd "$(dirname "$0")" && pwd)"

for cmd in kubectl helm; do
  command -v "$cmd" >/dev/null || { echo "$cmd fehlt (siehe README, Werkzeuge in WSL)" >&2; exit 1; }
done

echo "Cluster: $(kubectl config current-context)  (kubeconfig: ${KUBECONFIG:-~/.kube/config})"
kubectl cluster-info >/dev/null || { echo "Cluster nicht erreichbar" >&2; exit 1; }

# Hinweis: Helm installiert die CRDs aus der Chart nur bei der Erstinstallation.
# Bei einem Versionswechsel müssen sie gesondert aktualisiert werden (siehe README).
helm upgrade --install "$RELEASE" oci://docker.io/envoyproxy/gateway-helm \
  --version "$EG_VERSION" \
  --namespace "$NAMESPACE" --create-namespace \
  -f "$HERE/values.yaml"

kubectl -n "$NAMESPACE" wait --for=condition=Available deployment/envoy-gateway --timeout=5m
kubectl get crd gateways.gateway.networking.k8s.io httproutes.gateway.networking.k8s.io
