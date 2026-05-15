#!/usr/bin/env bash
set -euo pipefail
: "${KUBECONFIG:?export KUBECONFIG=\$HOME/.kube/k3s-goshop.yaml}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

kubectl apply -f "$SCRIPT_DIR/manifests/cluster-issuer-staging.yaml"
kubectl apply -f "$SCRIPT_DIR/manifests/cluster-issuer-prod.yaml"

echo "==> Waiting for issuers Ready (cert-manager validates ACME account creation)"
for i in 1 2 3 4 5 6; do
  if kubectl get clusterissuer letsencrypt-staging letsencrypt-prod \
       -o jsonpath='{.items[*].status.conditions[?(@.type=="Ready")].status}' | grep -q "True True"; then
    echo "    Both Ready."
    break
  fi
  sleep 5
done
kubectl get clusterissuer
