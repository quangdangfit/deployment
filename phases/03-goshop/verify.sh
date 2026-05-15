#!/usr/bin/env bash
set -euo pipefail
: "${KUBECONFIG:?export KUBECONFIG=\$HOME/.kube/k3s-goshop.yaml}"
: "${VM_IP:?export VM_IP=<oracle-vm-public-ip>}"

fail=0
check() {
  local msg="$1"; shift
  if "$@" >/dev/null 2>&1; then echo "  [OK]   $msg"; else echo "  [FAIL] $msg"; fail=1; fi
}

echo "==> Cluster checks"
check "namespace goshop exists" kubectl get ns goshop
check "deployment goshop Available" \
  kubectl -n goshop wait --for=condition=Available deployment/goshop --timeout=15s
check "service goshop has endpoints" \
  bash -c "test -n \"\$(kubectl -n goshop get endpoints goshop -o jsonpath='{.subsets[0].addresses[0].ip}')\""

echo "==> HTTP check"
code=$(curl -sS -o /dev/null -w '%{http_code}' "http://${VM_IP}:30088/healthz" || echo "000")
if [[ "$code" =~ ^(200|204)$ ]]; then
  echo "  [OK]   http://$VM_IP:30088/healthz returned $code"
else
  echo "  [WARN] http://$VM_IP:30088/healthz returned $code"
  echo "         Try /, /health, /api/v1/health. Or check OCI firewall for port 30088."
  fail=1
fi

exit $fail
