#!/usr/bin/env bash
set -euo pipefail
: "${KUBECONFIG:?export KUBECONFIG=\$HOME/.kube/k3s-goshop.yaml}"
DOMAIN="${DOMAIN:-goshop.cunghoclaptrinh.online}"

fail=0
check() { local m="$1"; shift; "$@" >/dev/null 2>&1 && echo "  [OK]   $m" || { echo "  [FAIL] $m"; fail=1; }; }

check "helm release goshop deployed" \
  bash -c "test \"\$(helm -n default list -f '^goshop$' -o json | python3 -c 'import json,sys;print(json.load(sys.stdin)[0][\"status\"])')\" = deployed"
check "deployment Available" kubectl -n default wait --for=condition=Available deployment -l app.kubernetes.io/name=goshop --timeout=10s
check "ingress exists" kubectl -n default get ingress goshop-goshop

code=$(curl -sS -o /dev/null -w '%{http_code}' "https://$DOMAIN/healthz" || echo 000)
echo "  [INFO] https://$DOMAIN/healthz -> $code"
[[ "$code" =~ ^(200|204)$ ]] || fail=1

exit $fail
