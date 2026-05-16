#!/usr/bin/env bash
set -euo pipefail
: "${KUBECONFIG:?export KUBECONFIG=\$HOME/.kube/k3s-goshop.yaml}"

helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
helm repo update prometheus-community >/dev/null

echo "==> Installing kube-prometheus-stack (Prometheus + Grafana + Alertmanager)"
helm upgrade --install kps prometheus-community/kube-prometheus-stack \
  --namespace monitoring --create-namespace \
  --set grafana.adminPassword="${GRAFANA_PASSWORD:-changeme-set-GRAFANA_PASSWORD}" \
  --set prometheus.prometheusSpec.retention=15d \
  --set prometheus.prometheusSpec.resources.requests.memory=512Mi \
  --set prometheus.prometheusSpec.resources.limits.memory=2Gi \
  --set prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.storageClassName=local-path \
  --set prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.resources.requests.storage=20Gi \
  --set grafana.persistence.enabled=true \
  --set grafana.persistence.storageClassName=local-path \
  --set grafana.persistence.size=5Gi \
  --wait --timeout 10m

echo
kubectl -n monitoring get pods
echo
echo "==> Access Grafana via port-forward, hoặc tạo Ingress riêng:"
echo "    kubectl -n monitoring port-forward svc/kps-grafana 3000:80"
echo "    open http://localhost:3000     (admin / \$GRAFANA_PASSWORD)"
