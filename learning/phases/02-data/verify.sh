#!/usr/bin/env bash
set -euo pipefail
: "${KUBECONFIG:?export KUBECONFIG=\$HOME/.kube/k3s-goshop.yaml}"

fail=0
check() {
  local msg="$1"; shift
  if "$@" >/dev/null 2>&1; then echo "  [OK]   $msg"; else echo "  [FAIL] $msg"; fail=1; fi
}

echo "==> Cluster checks"
check "namespace data exists" kubectl get ns data
check "postgres StatefulSet Ready" \
  kubectl -n data wait --for=jsonpath='{.status.readyReplicas}'=1 statefulset/postgres --timeout=10s
check "redis Deployment Available" \
  kubectl -n data wait --for=condition=Available deployment/redis --timeout=10s
check "PVC data-postgres-0 Bound" \
  bash -c "test \"\$(kubectl -n data get pvc data-postgres-0 -o jsonpath='{.status.phase}')\" = Bound"

echo "==> Connectivity checks"
# Postgres
if kubectl -n data run psql-verify --rm -i --restart=Never --image=postgres:16-alpine -- \
   psql 'postgres://goshop:goshop_dev@postgres:5432/goshop' -c 'SELECT 1;' 2>/dev/null | grep -q '1 row'; then
  echo "  [OK]   Postgres SELECT 1"
else
  echo "  [FAIL] Postgres SELECT 1"
  fail=1
fi

# Redis
if kubectl -n data run redis-verify --rm -i --restart=Never --image=redis:7-alpine -- \
   redis-cli -h redis -a redis_dev PING 2>/dev/null | grep -q PONG; then
  echo "  [OK]   Redis PING"
else
  echo "  [FAIL] Redis PING"
  fail=1
fi

exit $fail
