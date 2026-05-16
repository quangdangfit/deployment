#!/usr/bin/env bash
set -euo pipefail
: "${KUBECONFIG:?export KUBECONFIG=\$HOME/.kube/k3s-goshop.yaml}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

kubectl apply -f "$SCRIPT_DIR/manifests/goshop-ingress.yaml"

echo "==> Waiting for Certificate to be Ready (~30-60s typical)"
kubectl -n default wait --for=condition=Ready certificate/goshop-tls --timeout=180s || {
  echo "Certificate not Ready. Diagnose with:"
  echo "  kubectl -n default describe certificate goshop-tls"
  echo "  kubectl -n default describe challenge"
  exit 1
}

kubectl -n default get ingress,certificate
