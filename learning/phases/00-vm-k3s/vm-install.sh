#!/usr/bin/env bash
# Chạy TRÊN VM Oracle. Idempotent — chạy nhiều lần không hại.
# Required: PUBLIC_IP env var (để gắn vào TLS SAN của k3s API server).
set -euo pipefail

PUBLIC_IP="${PUBLIC_IP:?set PUBLIC_IP=<vm-public-ip> before running}"
DOMAIN="${DOMAIN:-goshop.cunghoclaptrinh.online}"

echo "==> Disabling swap (k3s requires)"
sudo swapoff -a
sudo sed -i.bak '/ swap / s/^/#/' /etc/fstab

echo "==> Removing Oracle Ubuntu iptables DROP rules"
# Oracle Ubuntu image cài sẵn iptables-persistent với rule DROP all input ngoại trừ 22.
# k3s cần CNI tự quản iptables → gỡ package + flush.
sudo apt-get purge -y iptables-persistent netfilter-persistent || true
sudo iptables -F INPUT || true
sudo iptables -F FORWARD || true

echo "==> Installing k3s"
# --disable traefik: dùng ingress-nginx ở Phase 4
# --disable servicelb: single-node không cần LB ảo
# --tls-san: thêm public IP + domain vào cert TLS để kubectl từ xa kết nối được
# --write-kubeconfig-mode 644: cho phép user thường đọc kubeconfig (tiện scp về local)
curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="\
  --disable traefik \
  --disable servicelb \
  --write-kubeconfig-mode 644 \
  --tls-san ${PUBLIC_IP} \
  --tls-san ${DOMAIN}" sh -

echo "==> Waiting for node Ready"
until sudo k3s kubectl get nodes 2>/dev/null | grep -q ' Ready '; do sleep 2; done
sudo k3s kubectl get nodes -o wide

echo "==> Done. From your workstation: scp /etc/rancher/k3s/k3s.yaml back and rewrite server URL."
