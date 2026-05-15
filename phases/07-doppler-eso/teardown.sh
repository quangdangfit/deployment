#!/usr/bin/env bash
set -euo pipefail
: "${KUBECONFIG:?export KUBECONFIG=\$HOME/.kube/k3s-goshop.yaml}"

kubectl -n goshop delete externalsecret goshop-secrets --ignore-not-found
kubectl -n data delete externalsecret postgres-credentials redis-credentials --ignore-not-found
kubectl delete clustersecretstore doppler --ignore-not-found

echo "==> To uninstall ESO entirely:"
echo "    helm -n external-secrets uninstall external-secrets"
echo "    kubectl delete ns external-secrets        # cũng xóa secret doppler-token"
