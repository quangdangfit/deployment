#!/usr/bin/env bash
set -euo pipefail

: "${KUBECONFIG:?export KUBECONFIG=\$HOME/.kube/k3s-goshop.yaml}"
: "${VM_IP:?export VM_IP=<oracle-vm-public-ip>}"

fail=0
check() {
  local msg="$1"; shift
  if "$@" >/dev/null 2>&1; then
    echo "  [OK]   $msg"
  else
    echo "  [FAIL] $msg"
    fail=1
  fi
}

echo "==> Cluster checks"
check "namespace hello-world exists" \
  kubectl get ns hello-world
check "deployment hello-nginx is Available" \
  kubectl -n hello-world wait --for=condition=Available deployment/hello-nginx --timeout=10s
check "service hello-nginx has endpoints" \
  bash -c "test -n \"\$(kubectl -n hello-world get endpoints hello-nginx -o jsonpath='{.subsets[0].addresses[0].ip}')\""

echo "==> External access"
code=$(curl -sS -o /dev/null -w '%{http_code}' "http://${VM_IP}:30080" || echo "000")
if [[ "$code" == "200" ]]; then
  echo "  [OK]   http://${VM_IP}:30080 returned 200"
else
  echo "  [FAIL] http://${VM_IP}:30080 returned $code"
  echo "         Hint: OCI Security List may not have port 30080 open"
  fail=1
fi

exit $fail
