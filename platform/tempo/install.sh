#!/usr/bin/env bash
# Tempo — single-binary monolithic mode. OTLP receivers on 4317/4318.
set -euo pipefail
: "${KUBECONFIG:?export KUBECONFIG=\$HOME/.kube/config}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

helm repo add grafana https://grafana.github.io/helm-charts >/dev/null 2>&1 || true
helm repo update grafana >/dev/null

helm upgrade --install tempo grafana/tempo \
  --namespace monitoring --create-namespace \
  -f "$SCRIPT_DIR/values.yaml" \
  --wait --timeout 5m

kubectl -n monitoring get pods -l app.kubernetes.io/name=tempo
