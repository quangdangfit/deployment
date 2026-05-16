#!/usr/bin/env bash
set -euo pipefail
: "${KUBECONFIG:?export KUBECONFIG=\$HOME/.kube/k3s-goshop.yaml}"

kubectl -n argocd delete app goshop --ignore-not-found
kubectl -n argocd delete ingress argocd --ignore-not-found
kubectl -n argocd delete certificate argocd-tls --ignore-not-found
kubectl -n argocd delete secret argocd-tls --ignore-not-found

echo "==> To uninstall ArgoCD entirely:"
echo "    helm -n argocd uninstall argocd && kubectl delete ns argocd"
