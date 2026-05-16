#!/usr/bin/env bash
set -euo pipefail
: "${KUBECONFIG:?export KUBECONFIG=\$HOME/.kube/k3s-goshop.yaml}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "==> Applying Ingress + Application"
kubectl apply -f "$SCRIPT_DIR/manifests/argocd-ingress.yaml"
kubectl apply -f "$SCRIPT_DIR/manifests/goshop-app.yaml"

echo "==> Waiting for Application to sync (~1-3 min)"
for i in $(seq 1 30); do
  status=$(kubectl -n argocd get app goshop -o jsonpath='{.status.sync.status}/{.status.health.status}' 2>/dev/null || echo "/")
  echo "    [$i/30] $status"
  [[ "$status" == "Synced/Healthy" ]] && break
  sleep 6
done

kubectl -n argocd get applications
