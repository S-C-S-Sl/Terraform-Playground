#!/usr/bin/env bash
# platform/rabbitmq/install.sh
# Installiert oder aktualisiert RabbitMQ (eigenes Helm-Chart) im Cluster der aktuellen kubeconfig.
# RabbitMQ läuft im eigenen Namespace "rabbitmq"; die Zugangsdaten der Dienste legt das Chart
# als Secrets in deren Namespaces an (values.yaml, clients).
#
#   bash platform/rabbitmq/install.sh
#   NAMESPACE=anderer bash platform/rabbitmq/install.sh --set auth.username=foo
set -euo pipefail

RELEASE="${RELEASE:-rabbitmq}"
NAMESPACE="${NAMESPACE:-rabbitmq}"
HERE="$(cd "$(dirname "$0")" && pwd)"

for cmd in kubectl helm; do
  command -v "$cmd" >/dev/null || { echo "$cmd fehlt (siehe README, Werkzeuge in WSL)" >&2; exit 1; }
done

echo "Cluster: $(kubectl config current-context)  Namespace: $NAMESPACE"
helm lint "$HERE/chart"

# Namespaces der Dienste müssen existieren, damit Helm dort die Client-Secrets anlegen kann.
# Sie gehören den Produkten, nicht diesem Release - deshalb hier per kubectl statt im Chart.
for ns in $(helm template "$RELEASE" "$HERE/chart" -n "$NAMESPACE" "$@" --show-only templates/client-secrets.yaml \
            | awk '/^  namespace:/ {print $2}' | sort -u); do
  kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  echo "Namespace vorhanden: $ns"
done

helm upgrade --install "$RELEASE" "$HERE/chart" \
  --namespace "$NAMESPACE" --create-namespace \
  "$@"

kubectl -n "$NAMESPACE" rollout status deploy/"$RELEASE" --timeout=5m
kubectl -n "$NAMESPACE" get pods,svc,httproute -l app.kubernetes.io/instance="$RELEASE"
kubectl get secret -A -l app.kubernetes.io/component=client-credentials,app.kubernetes.io/instance="$RELEASE"
