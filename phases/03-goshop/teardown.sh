#!/usr/bin/env bash
set -euo pipefail
: "${KUBECONFIG:?export KUBECONFIG=\$HOME/.kube/k3s-goshop.yaml}"
# Xóa từng resource trong ns default (KHÔNG xóa ns default).
kubectl delete deployment goshop --ignore-not-found
kubectl delete service goshop --ignore-not-found
kubectl delete configmap goshop-config --ignore-not-found
