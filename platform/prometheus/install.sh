#!/usr/bin/env bash
# kube-prometheus-stack — Prometheus + Alertmanager + node-exporter + kube-state-metrics.
# Grafana is intentionally disabled here (see platform/grafana).
set -euo pipefail
: "${KUBECONFIG:?export KUBECONFIG=\$HOME/.kube/config}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
helm repo update prometheus-community >/dev/null

helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace monitoring --create-namespace \
  -f "$SCRIPT_DIR/values.yaml" \
  --wait --timeout 10m

kubectl -n monitoring get pods
