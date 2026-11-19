#!/usr/bin/env bash
# platform/argocd/install.sh
# Installiert oder aktualisiert Argo CD im Namespace "argocd". Argo CD selbst wird per Helm
# installiert (es muss vor allem anderen da sein); was danach kommt, verwaltet Argo CD aus Git.
#
#   bash platform/argocd/install.sh
#   ARGOCD_CHART_VERSION=10.18.3 bash platform/argocd/install.sh
set -euo pipefail

# Chart 10.18.2 = Argo CD v3.6.2
ARGOCD_CHART_VERSION="${ARGOCD_CHART_VERSION:-10.18.2}"
NAMESPACE="argocd"
RELEASE="argocd"
HERE="$(cd "$(dirname "$0")" && pwd)"

for cmd in kubectl helm; do
  command -v "$cmd" >/dev/null || { echo "$cmd fehlt (siehe README, Werkzeuge in WSL)" >&2; exit 1; }
done

echo "Cluster: $(kubectl config current-context)  argo-cd Chart ${ARGOCD_CHART_VERSION}"
helm repo add argo https://argoproj.github.io/argo-helm >/dev/null 2>&1 || true
helm repo update argo >/dev/null

helm upgrade --install "$RELEASE" argo/argo-cd \
  --version "$ARGOCD_CHART_VERSION" \
  --namespace "$NAMESPACE" --create-namespace \
  -f "$HERE/values.yaml" \
  --wait --timeout 10m

kubectl -n "$NAMESPACE" get pods
kubectl -n "$NAMESPACE" get httproute

echo
echo "Anmeldung: http://argocd.k8s-lab  Benutzer admin, Passwort:"
echo "  kubectl -n $NAMESPACE get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo"
