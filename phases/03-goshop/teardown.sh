#!/usr/bin/env bash
set -euo pipefail
: "${KUBECONFIG:?export KUBECONFIG=\$HOME/.kube/k3s-goshop.yaml}"
kubectl delete deployment goshop-api goshop-web --ignore-not-found
kubectl delete service goshop-api goshop-web --ignore-not-found
kubectl delete configmap goshop-config --ignore-not-found
