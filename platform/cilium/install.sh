#!/usr/bin/env bash
# platform/cilium/install.sh
# Installiert oder aktualisiert Cilium im Cluster der aktuellen kubeconfig.
# Chart-Version und Werte stehen gemeinsam im Repo: Version hier, Werte in values.yaml.
#
#   bash platform/cilium/install.sh                        # Version aus dieser Datei
#   CILIUM_VERSION=1.20.5 bash platform/cilium/install.sh  # abweichende Version
set -euo pipefail

CILIUM_VERSION="${CILIUM_VERSION:-1.20.4}"
NAMESPACE="kube-system"
RELEASE="cilium"
HERE="$(cd "$(dirname "$0")" && pwd)"

for cmd in kubectl helm; do
  command -v "$cmd" >/dev/null || { echo "$cmd fehlt (siehe README, Werkzeuge in WSL)" >&2; exit 1; }
done

# Ziel-Cluster anzeigen, damit nicht versehentlich der falsche getroffen wird
echo "Cluster: $(kubectl config current-context)  (kubeconfig: ${KUBECONFIG:-~/.kube/config})"
kubectl cluster-info >/dev/null || { echo "Cluster nicht erreichbar" >&2; exit 1; }

# ipam.mode=kubernetes braucht einen podCIDR auf jedem Knoten
missing="$(kubectl get nodes -o go-template='{{range .items}}{{if not .spec.podCIDR}}{{.metadata.name}} {{end}}{{end}}')"
if [[ -n "$missing" ]]; then
  echo "Knoten ohne podCIDR: $missing" >&2
  echo "Ist podSubnet in der kubeadm-Konfiguration gesetzt?" >&2
  exit 1
fi

helm repo add cilium https://helm.cilium.io/ >/dev/null 2>&1 || true
helm repo update cilium >/dev/null

current="$(helm list -n "$NAMESPACE" -f "^${RELEASE}\$" -o json | grep -oE '"chart":"cilium-[^"]+"' | cut -d- -f2 | tr -d '"' || true)"
echo "Cilium: ${current:-nicht installiert} -> $CILIUM_VERSION"

helm upgrade --install "$RELEASE" cilium/cilium \
  --version "$CILIUM_VERSION" \
  --namespace "$NAMESPACE" \
  -f "$HERE/values.yaml"

kubectl -n "$NAMESPACE" rollout status ds/cilium --timeout=5m
kubectl -n "$NAMESPACE" rollout status deploy/cilium-operator --timeout=5m
kubectl get nodes
