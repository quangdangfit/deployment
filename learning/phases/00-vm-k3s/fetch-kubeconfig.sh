#!/usr/bin/env bash
# Tải kubeconfig từ VM về local, rewrite server URL để kết nối qua public IP.
set -euo pipefail

: "${VM_IP:?export VM_IP=<oracle-vm-public-ip>}"
: "${VM_USER:=ubuntu}"
: "${VM_SSH_KEY:=$HOME/.ssh/oci_goshop}"
: "${KUBECONFIG:=$HOME/.kube/k3s-goshop.yaml}"

mkdir -p "$(dirname "$KUBECONFIG")"

echo "==> Fetching kubeconfig from VM"
ssh -i "$VM_SSH_KEY" "$VM_USER@$VM_IP" "sudo cat /etc/rancher/k3s/k3s.yaml" \
  | sed "s|https://127.0.0.1:6443|https://$VM_IP:6443|" \
  > "$KUBECONFIG"
chmod 600 "$KUBECONFIG"

echo "==> Verifying"
kubectl --kubeconfig "$KUBECONFIG" get nodes -o wide

echo
echo "==> Kubeconfig written to $KUBECONFIG"
echo "    Add to your shell rc:  export KUBECONFIG=$KUBECONFIG"
