#!/usr/bin/env bash
# Grafana — UI with Prometheus + Tempo datasources, exposed at
# https://grafana.cunghoclaptrinh.online via ingress-nginx + cert-manager.
set -euo pipefail
: "${KUBECONFIG:?export KUBECONFIG=\$HOME/.kube/config}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

helm repo add grafana https://grafana.github.io/helm-charts >/dev/null 2>&1 || true
helm repo update grafana >/dev/null

helm upgrade --install grafana grafana/grafana \
  --namespace monitoring --create-namespace \
  -f "$SCRIPT_DIR/values.yaml" \
  --wait --timeout 5m

kubectl apply -f "$SCRIPT_DIR/ingress.yaml"

echo
echo "Grafana admin password:"
kubectl -n monitoring get secret grafana -o jsonpath='{.data.admin-password}' | base64 -d
echo
echo "URL: https://grafana.cunghoclaptrinh.online (user: admin)"
