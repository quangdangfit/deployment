#!/usr/bin/env bash
set -euo pipefail
: "${KUBECONFIG:?export KUBECONFIG=\$HOME/.kube/k3s-goshop.yaml}"

# Lưu ý: xoá ns sẽ xoá PVC → PV → data thực mất luôn.
kubectl delete ns data --ignore-not-found
