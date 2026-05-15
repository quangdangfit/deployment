#!/usr/bin/env bash
set -euo pipefail
: "${KUBECONFIG:?export KUBECONFIG=\$HOME/.kube/k3s-goshop.yaml}"

helm repo add argo https://argoproj.github.io/argo-helm >/dev/null 2>&1 || true
helm repo update argo >/dev/null

echo "==> Installing ArgoCD Image Updater"
helm upgrade --install argocd-image-updater argo/argocd-image-updater \
  --namespace argocd \
  --set config.argocd.grpcWeb=true \
  --set config.argocd.serverAddress=argocd-server.argocd.svc.cluster.local \
  --set config.argocd.insecure=true \
  --set config.argocd.plaintext=true \
  --wait --timeout 3m

kubectl -n argocd get pods -l app.kubernetes.io/name=argocd-image-updater
