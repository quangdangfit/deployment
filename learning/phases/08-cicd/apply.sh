#!/usr/bin/env bash
set -euo pipefail
: "${KUBECONFIG:?export KUBECONFIG=\$HOME/.kube/k3s-goshop.yaml}"
: "${GHCR_USER:?export GHCR_USER=<github-username>}"
: "${GHCR_TOKEN:?export GHCR_TOKEN=<PAT with repo scope (git write-back) + read:packages>}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "==> Seeding git-creds Secret (Argo CD repo-creds for AIU write-back)"
kubectl -n argocd create secret generic git-creds \
  --from-literal=type=git \
  --from-literal=url=https://github.com/quangdangfit/deployment \
  --from-literal=username="$GHCR_USER" \
  --from-literal=password="$GHCR_TOKEN" \
  --dry-run=client -o yaml | \
  kubectl label --local -f - argocd.argoproj.io/secret-type=repo-creds -o yaml | \
  kubectl apply -f -

echo "==> Applying ImageUpdater CR (AIU v1.x — CRD-based, không xài annotation)"
kubectl apply -f "$SCRIPT_DIR/manifests/goshop-imageupdater.yaml"

echo
echo "==> Watch image-updater logs:"
echo "    kubectl -n argocd logs -l app.kubernetes.io/name=argocd-image-updater -f"
