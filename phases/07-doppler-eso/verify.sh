#!/usr/bin/env bash
set -euo pipefail
: "${KUBECONFIG:?export KUBECONFIG=\$HOME/.kube/k3s-goshop.yaml}"

fail=0
check() { local m="$1"; shift; "$@" >/dev/null 2>&1 && echo "  [OK]   $m" || { echo "  [FAIL] $m"; fail=1; }; }

check "ESO controller pod Ready" \
  kubectl -n external-secrets wait --for=condition=Ready pod -l app.kubernetes.io/name=external-secrets --timeout=10s
check "ClusterSecretStore doppler Ready" \
  bash -c "test \"\$(kubectl get clustersecretstore doppler -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}')\" = True"

for es in "data/postgres-credentials" "data/redis-credentials" "goshop/goshop-secrets"; do
  ns="${es%%/*}"; name="${es##*/}"
  check "ExternalSecret $ns/$name SecretSynced" \
    bash -c "test \"\$(kubectl -n $ns get externalsecret $name -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}')\" = True"
  check "Secret $ns/$name exists" \
    kubectl -n $ns get secret $name
done

exit $fail
