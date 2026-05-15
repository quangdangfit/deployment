#!/usr/bin/env bash
# Idempotent k3s bring-up for a fresh Oracle Ubuntu 22.04 A1.Flex VM.
# Run on the VM as a user with sudo.
set -euo pipefail

PUBLIC_IP="${PUBLIC_IP:?set PUBLIC_IP=<vm-public-ip> before running}"
DOMAIN="${DOMAIN:-goshop.cunghoclaptrinh.online}"

echo "==> Disabling swap"
sudo swapoff -a
sudo sed -i.bak '/ swap / s/^/#/' /etc/fstab

echo "==> Removing Oracle's iptables DROP rules (k3s needs them gone)"
sudo apt-get purge -y iptables-persistent netfilter-persistent || true
sudo iptables -F INPUT || true
sudo iptables -F FORWARD || true

echo "==> Installing k3s"
curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="\
  --disable traefik \
  --disable servicelb \
  --write-kubeconfig-mode 644 \
  --tls-san ${PUBLIC_IP} \
  --tls-san ${DOMAIN}" sh -

echo "==> Waiting for node Ready"
until sudo k3s kubectl get nodes 2>/dev/null | grep -q ' Ready '; do sleep 2; done
sudo k3s kubectl get nodes -o wide

echo "==> Done. Copy /etc/rancher/k3s/k3s.yaml to your workstation."
