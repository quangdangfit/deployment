#!/usr/bin/env bash
set -euo pipefail
: "${KUBECONFIG:?export KUBECONFIG=\$HOME/.kube/k3s-goshop.yaml}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

kubectl apply -f "$SCRIPT_DIR/manifests/cluster-issuer-prod.yaml"

echo "==> Waiting for issuer Ready (cert-manager validates ACME account creation)"
for i in 1 2 3 4 5 6; do
  if [[ "$(kubectl get clusterissuer letsencrypt-prod \
       -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')" == "True" ]]; then
    echo "    Ready."
    break
  fi
  sleep 5
done
kubectl get clusterissuer
