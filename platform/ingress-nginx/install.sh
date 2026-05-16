#!/usr/bin/env bash
# ingress-nginx — DaemonSet hostNetwork (single-node k3s, no cloud LB).
set -euo pipefail
: "${KUBECONFIG:?export KUBECONFIG=\$HOME/.kube/config}"

helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx >/dev/null 2>&1 || true
helm repo update ingress-nginx >/dev/null

helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx --create-namespace \
  --set controller.kind=DaemonSet \
  --set controller.hostNetwork=true \
  --set controller.hostPort.enabled=true \
  --set controller.hostPort.ports.http=80 \
  --set controller.hostPort.ports.https=443 \
  --set controller.dnsPolicy=ClusterFirstWithHostNet \
  --set controller.service.enabled=false \
  --set controller.ingressClassResource.default=true \
  --set controller.config.use-forwarded-headers=true \
  --set controller.config.proxy-body-size=16m \
  --wait --timeout 5m

kubectl -n ingress-nginx get pods -o wide
