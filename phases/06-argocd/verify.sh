#!/usr/bin/env bash
set -euo pipefail
: "${KUBECONFIG:?export KUBECONFIG=\$HOME/.kube/k3s-goshop.yaml}"

fail=0
check() { local m="$1"; shift; "$@" >/dev/null 2>&1 && echo "  [OK]   $m" || { echo "  [FAIL] $m"; fail=1; }; }

check "ArgoCD server Ready" \
  kubectl -n argocd wait --for=condition=Available deployment/argocd-server --timeout=10s
check "ArgoCD ingress Cert Ready" \
  kubectl -n argocd wait --for=condition=Ready certificate/argocd-tls --timeout=10s
sync=$(kubectl -n argocd get app goshop -o jsonpath='{.status.sync.status}/{.status.health.status}' 2>/dev/null || echo "/")
if [[ "$sync" == "Synced/Healthy" ]]; then
  echo "  [OK]   Application goshop: Synced/Healthy"
else
  echo "  [FAIL] Application goshop: $sync"
  fail=1
fi
exit $fail
