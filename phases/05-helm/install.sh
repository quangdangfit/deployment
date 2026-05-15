#!/usr/bin/env bash
# Cách dùng:  ./install.sh [dev|prod]   (default: dev)
set -euo pipefail
: "${KUBECONFIG:?export KUBECONFIG=\$HOME/.kube/k3s-goshop.yaml}"
: "${GHCR_USER:=quangdangfit}"
: "${IMAGE_TAG:=phase5}"

PROFILE="${1:-dev}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHART="$SCRIPT_DIR/chart/goshop"

VALUES_FILES=( "-f" "$CHART/values.yaml" )
if [[ "$PROFILE" == "prod" ]]; then
  VALUES_FILES+=( "-f" "$CHART/values-prod.yaml" )
fi

echo "==> Linting chart"
helm lint "$CHART"

echo "==> Installing/upgrading (profile=$PROFILE, image=$GHCR_USER/goshop:$IMAGE_TAG)"
helm upgrade --install goshop "$CHART" \
  --namespace goshop --create-namespace \
  "${VALUES_FILES[@]}" \
  --set image.repository="ghcr.io/$GHCR_USER/goshop" \
  --set image.tag="$IMAGE_TAG" \
  --wait --timeout 5m

echo
helm -n goshop list
kubectl -n goshop get pods,svc,ingress
