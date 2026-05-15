#!/usr/bin/env bash
# Chạy TỪ MÁY LOCAL. Push vm-install.sh lên VM và execute.
set -euo pipefail

: "${VM_IP:?export VM_IP=<oracle-vm-public-ip>}"
: "${VM_USER:=ubuntu}"
: "${VM_SSH_KEY:=$HOME/.ssh/oci_goshop}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "==> Uploading vm-install.sh to $VM_USER@$VM_IP"
scp -i "$VM_SSH_KEY" -o StrictHostKeyChecking=accept-new \
    "$SCRIPT_DIR/vm-install.sh" \
    "$VM_USER@$VM_IP:/tmp/vm-install.sh"

echo "==> Executing on VM"
ssh -i "$VM_SSH_KEY" "$VM_USER@$VM_IP" \
    "PUBLIC_IP=$VM_IP bash /tmp/vm-install.sh"

echo
echo "==> k3s installed. Next: ./fetch-kubeconfig.sh"
