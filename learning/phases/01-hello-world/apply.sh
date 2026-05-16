#!/usr/bin/env bash
set -euo pipefail

: "${KUBECONFIG:?export KUBECONFIG=\$HOME/.kube/k3s-goshop.yaml}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "==> Applying manifests"
kubectl apply -f "$SCRIPT_DIR/manifests/"

echo "==> Waiting for Deployment rollout"
kubectl -n hello-world rollout status deployment/hello-nginx --timeout=120s

echo
echo "==> Resources:"
kubectl -n hello-world get all

echo
echo "==> Test:  curl http://\$VM_IP:30080"
