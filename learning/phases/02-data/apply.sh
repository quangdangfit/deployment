#!/usr/bin/env bash
set -euo pipefail
: "${KUBECONFIG:?export KUBECONFIG=\$HOME/.kube/k3s-goshop.yaml}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "==> Applying manifests"
kubectl apply -f "$SCRIPT_DIR/manifests/"

echo "==> Waiting for Postgres"
kubectl -n data rollout status statefulset/postgres --timeout=180s
echo "==> Waiting for Redis"
kubectl -n data rollout status deployment/redis --timeout=120s

echo
kubectl -n data get pods,pvc,svc
