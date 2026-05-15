#!/usr/bin/env bash
set -euo pipefail
: "${KUBECONFIG:?export KUBECONFIG=\$HOME/.kube/k3s-goshop.yaml}"

# Chỉ rút Ingress + Certificate của goshop. Giữ ingress-nginx + cert-manager để Phase sau dùng.
kubectl -n default delete ingress goshop --ignore-not-found
kubectl -n default delete certificate goshop-tls --ignore-not-found
kubectl -n default delete secret goshop-tls --ignore-not-found
kubectl delete clusterissuer letsencrypt-staging letsencrypt-prod --ignore-not-found

echo "==> To uninstall platform charts:"
echo "    helm -n ingress-nginx uninstall ingress-nginx && kubectl delete ns ingress-nginx"
echo "    helm -n cert-manager  uninstall cert-manager  && kubectl delete ns cert-manager"
