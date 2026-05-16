#!/usr/bin/env bash
set -euo pipefail
: "${KUBECONFIG:?export KUBECONFIG=\$HOME/.kube/k3s-goshop.yaml}"
DOMAIN="${DOMAIN:-goshop.cunghoclaptrinh.online}"

fail=0
check() { local m="$1"; shift; "$@" >/dev/null 2>&1 && echo "  [OK]   $m" || { echo "  [FAIL] $m"; fail=1; }; }

echo "==> Platform"
check "ingress-nginx pod Ready" kubectl -n ingress-nginx wait --for=condition=Ready pod -l app.kubernetes.io/component=controller --timeout=10s
check "cert-manager pod Ready" kubectl -n cert-manager wait --for=condition=Ready pod -l app.kubernetes.io/instance=cert-manager --timeout=10s
check "ClusterIssuer letsencrypt-prod Ready" \
  bash -c "test \"\$(kubectl get clusterissuer letsencrypt-prod -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}')\" = True"

echo "==> Certificate"
check "Certificate goshop-tls Ready" \
  kubectl -n default wait --for=condition=Ready certificate/goshop-tls --timeout=10s

echo "==> HTTPS"
code=$(curl -sS -o /dev/null -w '%{http_code}' "https://$DOMAIN/health" || echo 000)
verify=$(curl -sS -o /dev/null -w '%{ssl_verify_result}' "https://$DOMAIN/health" || echo "?")
if [[ "$code" =~ ^(200|204)$ && "$verify" == "0" ]]; then
  echo "  [OK]   https://$DOMAIN/health = $code, cert valid"
else
  echo "  [FAIL] https://$DOMAIN/health returned $code, verify=$verify"
  fail=1
fi

exit $fail
