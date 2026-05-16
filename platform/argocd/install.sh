#!/usr/bin/env bash
set -euo pipefail
: "${KUBECONFIG:?export KUBECONFIG=\$HOME/.kube/config}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

helm repo add argo https://argoproj.github.io/argo-helm >/dev/null 2>&1 || true
helm repo update argo >/dev/null

helm upgrade --install argocd argo/argo-cd \
  --namespace argocd --create-namespace \
  --set global.domain=argocd.cunghoclaptrinh.online \
  --set configs.params."server\.insecure"=true \
  --set dex.enabled=false \
  --set notifications.enabled=false \
  --set server.replicas=1 \
  --set repoServer.replicas=1 \
  --set applicationSet.replicas=1 \
  --set controller.resources.requests.cpu=100m \
  --set controller.resources.requests.memory=256Mi \
  --set redis.resources.requests.cpu=50m \
  --set redis.resources.requests.memory=64Mi \
  --wait --timeout 5m

kubectl apply -f "$SCRIPT_DIR/ingress.yaml"

echo "==> Initial admin password:"
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d; echo
echo "    URL: https://argocd.cunghoclaptrinh.online"
