#!/usr/bin/env bash
set -euo pipefail
: "${KUBECONFIG:?export KUBECONFIG=\$HOME/.kube/k3s-goshop.yaml}"

helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx >/dev/null 2>&1 || true
helm repo update ingress-nginx >/dev/null

echo "==> Installing ingress-nginx (DaemonSet hostNetwork on port 80/443)"
# Vì single-node k3s không có cloud LB, mình chạy ingress như DaemonSet với hostNetwork
# → pod bind trực tiếp port 80/443 trên VM, không cần Service LoadBalancer.
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

echo
kubectl -n ingress-nginx get pods -o wide
echo
echo "==> Test from outside: curl -I http://\$VM_IP    (should return 404 from nginx)"
