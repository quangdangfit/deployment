#!/usr/bin/env bash
set -euo pipefail
: "${KUBECONFIG:?export KUBECONFIG=\$HOME/.kube/k3s-goshop.yaml}"
# Chỉ xoá ns goshop. Giữ nguyên ns data (Phase 2) để khỏi mất Postgres data.
kubectl delete ns goshop --ignore-not-found
