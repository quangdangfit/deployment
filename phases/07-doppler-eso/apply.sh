#!/usr/bin/env bash
set -euo pipefail
: "${KUBECONFIG:?export KUBECONFIG=\$HOME/.kube/k3s-goshop.yaml}"
: "${DOPPLER_TOKEN:?export DOPPLER_TOKEN=dp.st.prd.xxx}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "==> Seeding doppler-token Secret in external-secrets ns"
kubectl create ns external-secrets --dry-run=client -o yaml | kubectl apply -f -
kubectl -n external-secrets create secret generic doppler-token \
  --from-literal=dopplerToken="$DOPPLER_TOKEN" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "==> Applying ClusterSecretStore + ExternalSecrets"
kubectl apply -f "$SCRIPT_DIR/manifests/cluster-secret-store.yaml"
# Đảm bảo ns data, goshop tồn tại (chúng có thể đã có từ phase trước)
kubectl create ns data --dry-run=client -o yaml | kubectl apply -f -
kubectl create ns goshop --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f "$SCRIPT_DIR/manifests/data-externalsecrets.yaml"
kubectl apply -f "$SCRIPT_DIR/manifests/goshop-externalsecret.yaml"

echo "==> Waiting for ClusterSecretStore Valid"
for i in 1 2 3 4 5 6; do
  s=$(kubectl get clustersecretstore doppler -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
  [[ "$s" == "True" ]] && break
  sleep 5
done

echo "==> Status"
kubectl get clustersecretstore doppler
kubectl -n data get externalsecret
kubectl -n goshop get externalsecret
