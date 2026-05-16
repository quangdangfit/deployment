#!/usr/bin/env bash
set -euo pipefail
: "${KUBECONFIG:?export KUBECONFIG=\$HOME/.kube/k3s-goshop.yaml}"

helm repo add jetstack https://charts.jetstack.io >/dev/null 2>&1 || true
helm repo update jetstack >/dev/null

echo "==> Installing cert-manager (with CRDs)"
helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace cert-manager --create-namespace \
  --set installCRDs=true \
  --set resources.requests.cpu=50m \
  --set resources.requests.memory=64Mi \
  --wait --timeout 5m

echo
kubectl -n cert-manager get pods
