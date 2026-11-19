#!/usr/bin/env bash
# platform/rabbitmq/install.sh
# Installiert oder aktualisiert RabbitMQ (eigenes Helm-Chart) im Cluster der aktuellen kubeconfig.
# Standard-Namespace ist der der Anwendungen ("demo"), weil diese das Secret mit den
# Zugangsdaten nur im eigenen Namespace lesen können.
#
#   bash platform/rabbitmq/install.sh
#   NAMESPACE=anderer bash platform/rabbitmq/install.sh --set auth.username=foo
set -euo pipefail

RELEASE="${RELEASE:-rabbitmq}"
NAMESPACE="${NAMESPACE:-demo}"
HERE="$(cd "$(dirname "$0")" && pwd)"

for cmd in kubectl helm; do
  command -v "$cmd" >/dev/null || { echo "$cmd fehlt (siehe README, Werkzeuge in WSL)" >&2; exit 1; }
done

echo "Cluster: $(kubectl config current-context)  Namespace: $NAMESPACE"
helm lint "$HERE/chart"
helm upgrade --install "$RELEASE" "$HERE/chart" \
  --namespace "$NAMESPACE" --create-namespace \
  "$@"

kubectl -n "$NAMESPACE" rollout status deploy/"$RELEASE" --timeout=5m
kubectl -n "$NAMESPACE" get pods,svc,httproute -l app.kubernetes.io/instance="$RELEASE"
