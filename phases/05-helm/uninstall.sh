#!/usr/bin/env bash
set -euo pipefail
: "${KUBECONFIG:?export KUBECONFIG=\$HOME/.kube/k3s-goshop.yaml}"
helm -n goshop uninstall goshop || true
# Optional: kubectl delete ns goshop
