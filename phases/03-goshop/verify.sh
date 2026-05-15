#!/usr/bin/env bash
set -euo pipefail
: "${KUBECONFIG:?export KUBECONFIG=\$HOME/.kube/k3s-goshop.yaml}"
: "${VM_IP:?export VM_IP=<oracle-vm-public-ip>}"

fail=0
check() {
  local msg="$1"; shift
  if "$@" >/dev/null 2>&1; then echo "  [OK]   $msg"; else echo "  [FAIL] $msg"; fail=1; fi
}

echo "==> Cluster"
check "deployment goshop-api Available" \
  kubectl wait --for=condition=Available deployment/goshop-api --timeout=15s
check "deployment goshop-web Available" \
  kubectl wait --for=condition=Available deployment/goshop-web --timeout=15s
check "service goshop-api has endpoints" \
  bash -c "test -n \"\$(kubectl get endpoints goshop-api -o jsonpath='{.subsets[0].addresses[0].ip}')\""
check "service goshop-web has endpoints" \
  bash -c "test -n \"\$(kubectl get endpoints goshop-web -o jsonpath='{.subsets[0].addresses[0].ip}')\""

echo "==> HTTP"
code=$(curl -sS -o /dev/null -w '%{http_code}' "http://${VM_IP}:30088/" || echo 000)
[[ "$code" == "200" ]] && echo "  [OK]   FE index http://$VM_IP:30088/ = $code" || { echo "  [FAIL] FE / = $code"; fail=1; }

code=$(curl -sS -o /dev/null -w '%{http_code}' "http://${VM_IP}:30088/health" || echo 000)
[[ "$code" =~ ^(200|204)$ ]] && echo "  [OK]   FE → BE /health = $code" || { echo "  [FAIL] /health = $code"; fail=1; }

exit $fail
