#!/usr/bin/env bash
set -euo pipefail
: "${KUBECONFIG:?export KUBECONFIG=\$HOME/.kube/k3s-goshop.yaml}"
: "${GIT_USER:?export GIT_USER=<github-username>}"
: "${GIT_TOKEN:?export GIT_TOKEN=<PAT with repo scope>}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "==> Seeding git-creds Secret"
export GIT_USER GIT_TOKEN
envsubst < "$SCRIPT_DIR/manifests/git-creds-secret.yaml.tpl" | kubectl apply -f -

echo "==> Applying Application with Image Updater annotations"
kubectl apply -f "$SCRIPT_DIR/manifests/goshop-app-updated.yaml"

echo
echo "==> Watch image-updater logs to see it pick up new tags:"
echo "    kubectl -n argocd logs -l app.kubernetes.io/name=argocd-image-updater -f"
