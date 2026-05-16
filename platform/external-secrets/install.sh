#!/usr/bin/env bash
# External Secrets Operator + Doppler ClusterSecretStore.
# Bootstrap: DOPPLER_TOKEN env required to seed the auth secret (ESO can't sync its own token).
set -euo pipefail
: "${KUBECONFIG:?export KUBECONFIG=\$HOME/.kube/config}"
: "${DOPPLER_TOKEN:?export DOPPLER_TOKEN=dp.st.prd.xxx}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

helm repo add external-secrets https://charts.external-secrets.io >/dev/null 2>&1 || true
helm repo update external-secrets >/dev/null

helm upgrade --install external-secrets external-secrets/external-secrets \
  --namespace external-secrets --create-namespace \
  --set installCRDs=true \
  --wait --timeout 5m

kubectl -n external-secrets create secret generic doppler-token \
  --from-literal=dopplerToken="$DOPPLER_TOKEN" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl apply -f "$SCRIPT_DIR/cluster-secret-store.yaml"

for i in 1 2 3 4 5 6; do
  s=$(kubectl get clustersecretstore doppler -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
  [[ "$s" == "True" ]] && break
  sleep 5
done
kubectl get clustersecretstore doppler
