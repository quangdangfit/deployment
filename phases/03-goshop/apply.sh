#!/usr/bin/env bash
set -euo pipefail
: "${KUBECONFIG:?export KUBECONFIG=\$HOME/.kube/k3s-goshop.yaml}"
: "${GHCR_USER:?export GHCR_USER=<github-username>}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP="$(mktemp -d)"
trap "rm -rf $TMP" EXIT

echo "==> Rendering manifests (injecting GHCR_USER=$GHCR_USER)"
cp -r "$SCRIPT_DIR/manifests" "$TMP/"
sed -i.bak "s|GHCR_USER_PLACEHOLDER|$GHCR_USER|g" "$TMP/manifests/20-deployment.yaml"
rm "$TMP/manifests/"*.bak

echo "==> Applying"
kubectl apply -f "$TMP/manifests/"

echo "==> Waiting for rollout"
kubectl -n goshop rollout status deployment/goshop --timeout=180s

echo
kubectl -n goshop get pods,svc

echo
echo "==> Smoke test:"
echo "    curl http://\$VM_IP:30088/healthz"
