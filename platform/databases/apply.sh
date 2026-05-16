#!/usr/bin/env bash
# Shared Postgres + Redis in `data` namespace. Apps reference them via:
#   postgres.data.svc.cluster.local:5432
#   redis.data.svc.cluster.local:6379
# Credentials come from Doppler via External Secrets (requires platform/external-secrets first).
set -euo pipefail
: "${KUBECONFIG:?export KUBECONFIG=\$HOME/.kube/config}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

kubectl apply -f "$SCRIPT_DIR/namespace.yaml"
kubectl apply -f "$SCRIPT_DIR/postgres/externalsecret.yaml"
kubectl apply -f "$SCRIPT_DIR/redis/externalsecret.yaml"
kubectl apply -f "$SCRIPT_DIR/postgres/manifests/"
kubectl apply -f "$SCRIPT_DIR/redis/manifests/"

kubectl -n data get pods
