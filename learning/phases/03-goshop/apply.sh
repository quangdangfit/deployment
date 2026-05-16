#!/usr/bin/env bash
set -euo pipefail
: "${KUBECONFIG:?export KUBECONFIG=\$HOME/.kube/k3s-goshop.yaml}"
: "${GHCR_USER:?export GHCR_USER=<github-username>}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP="$(mktemp -d)"
trap "rm -rf $TMP" EXIT

echo "==> Rendering manifests (GHCR_USER=$GHCR_USER)"
cp -r "$SCRIPT_DIR/manifests" "$TMP/"
sed -i.bak "s|GHCR_USER_PLACEHOLDER|$GHCR_USER|g" \
  "$TMP/manifests/20-api-deployment.yaml" \
  "$TMP/manifests/40-web-deployment.yaml"
rm "$TMP/manifests/"*.bak

echo "==> Applying"
kubectl apply -f "$TMP/manifests/"

echo "==> Waiting for BE rollout"
kubectl rollout status deployment/goshop-api --timeout=180s
echo "==> Waiting for FE rollout"
kubectl rollout status deployment/goshop-web --timeout=180s

echo
kubectl get pods,svc -l 'app in (goshop-api,goshop-web)'

echo
echo "==> Smoke test:"
echo "    curl http://\$VM_IP:30088/         # FE index.html"
echo "    curl http://\$VM_IP:30088/health   # proxy → BE /health"
echo "    curl http://\$VM_IP:30088/api/...  # proxy → BE /api/..."
