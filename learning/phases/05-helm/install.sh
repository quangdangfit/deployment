#!/usr/bin/env bash
# Cách dùng:  ./install.sh
set -euo pipefail
: "${KUBECONFIG:?export KUBECONFIG=\$HOME/.kube/k3s-goshop.yaml}"
: "${GHCR_USER:=quangdangfit}"
: "${IMAGE_TAG:=master}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHART="$SCRIPT_DIR/chart/goshop"

echo "==> Linting chart"
helm lint "$CHART"

# Release name PHẢI là "goshop" — FE nginx.conf hardcode upstream "goshop-api".
# (Chart sinh tên service api = "<release>-api"; release "goshop" → "goshop-api" khớp.)
echo "==> Installing/upgrading (tag=$IMAGE_TAG)"
helm upgrade --install goshop "$CHART" \
  --namespace default --create-namespace \
  -f "$CHART/values.yaml" \
  --set api.image.repository="ghcr.io/$GHCR_USER/goshop" \
  --set api.image.tag="$IMAGE_TAG" \
  --set web.image.repository="ghcr.io/$GHCR_USER/goshop-web" \
  --set web.image.tag="$IMAGE_TAG" \
  --wait --timeout 5m

echo
helm -n default list
kubectl -n default get pods,svc,ingress -l app.kubernetes.io/name=goshop
