#!/usr/bin/env bash
set -euo pipefail
: "${KUBECONFIG:?export KUBECONFIG=\$HOME/.kube/k3s-goshop.yaml}"
: "${GHCR_USER:?export GHCR_USER=<github-username>}"
: "${GHCR_TOKEN:?export GHCR_TOKEN=<PAT with read:packages>}"

helm repo add argo https://argoproj.github.io/argo-helm >/dev/null 2>&1 || true
helm repo update argo >/dev/null

echo "==> Creating ghcr pull secret (docker-registry type)"
kubectl -n argocd create secret docker-registry ghcr-creds \
  --docker-server=ghcr.io \
  --docker-username="$GHCR_USER" \
  --docker-password="$GHCR_TOKEN" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "==> Installing ArgoCD Image Updater"
helm upgrade --install argocd-image-updater argo/argocd-image-updater \
  --namespace argocd \
  --set config.argocd.grpcWeb=true \
  --set config.argocd.serverAddress=argocd-server.argocd.svc.cluster.local \
  --set config.argocd.insecure=true \
  --set config.argocd.plaintext=true \
  --set-json 'config.registries=[{"name":"GitHub Container Registry","api_url":"https://ghcr.io","prefix":"ghcr.io","ping":true,"credentials":"pullsecret:argocd/ghcr-creds","credsexpire":"6h"}]' \
  --wait --timeout 3m

kubectl -n argocd rollout restart deployment argocd-image-updater-controller
kubectl -n argocd get pods -l app.kubernetes.io/name=argocd-image-updater
