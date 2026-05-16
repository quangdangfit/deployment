# Phase 0 — VM + k3s Foundation

## Mục tiêu

Sau phase này bạn có:
- 1 VM Oracle Cloud A1.Flex (ARM, 2 OCPU, 16 GB RAM) đã mở port 22/80/443/6443
- k3s chạy ổn định trên VM, node ở trạng thái `Ready`
- File `~/.kube/k3s-goshop.yaml` trên máy local để chạy `kubectl` từ xa

**Đầu ra mong đợi:**
```bash
$ kubectl get nodes
NAME                     STATUS   ROLES                  AGE   VERSION
instance-...             Ready    control-plane,master   2m    v1.31.x+k3s1
```

## Kiến thức nền

### k8s vs k3s

- **Kubernetes (k8s):** orchestrator container chuẩn, kiến trúc nhiều component (kube-apiserver, etcd, controller-manager, scheduler, kubelet, kube-proxy). Production-grade nhưng tốn RAM (~2GB chỉ riêng control plane).
- **k3s:** distro k8s do Rancher đóng gói, mọi component nén thành 1 binary < 100 MB. Mặc định dùng SQLite thay etcd, containerd thay Docker. Phù hợp single-node, edge, lab. **API tương thích 100% k8s** — kubectl, helm, manifest dùng giống hệt.

Mình chọn k3s vì VM chỉ có 16 GB RAM và muốn dồn RAM cho app.

### Tại sao Oracle A1.Flex?

- **Free Tier vĩnh viễn:** 4 OCPU + 24 GB RAM ARM (chia tối đa cho 4 VM)
- **ARM64:** nhanh, ít nóng, nhưng nhớ build image **multi-arch** (Phase 3)
- **IP public miễn phí:** 1 ephemeral hoặc reserved

### Phòng tuyến mạng

```
Internet
   │
   ▼
[Oracle Cloud Security List/NSG]  ← Layer 1: cloud firewall, phải mở port ở đây trước
   │
   ▼
[Ubuntu iptables (netfilter-persistent)]  ← Layer 2: Oracle Ubuntu image cài sẵn rule DROP, k3s sẽ xung đột → ta sẽ gỡ
   │
   ▼
[k3s node]
```

→ Mở port phải ở **cả 2 layer**. Script `install-k3s.sh` tự gỡ iptables-persistent.

### Port cần mở

| Port | Mục đích | Mở từ đâu |
|---|---|---|
| 22 | SSH | IP admin của bạn |
| 80 | HTTP (Let's Encrypt HTTP-01 challenge, sau này) | 0.0.0.0/0 |
| 443 | HTTPS (app traffic) | 0.0.0.0/0 |
| 6443 | k8s API (kubectl từ xa) | IP admin của bạn |

→ **Không** mở 6443 cho `0.0.0.0/0` — đó là endpoint quản trị toàn cluster.

## Các bước

### Step 1 — Tạo VM trên Oracle Cloud (manual UI, một lần)

Trong OCI Console:
1. Compute → Instances → Create instance
2. **Shape:** Ampere → VM.Standard.A1.Flex → **2 OCPU, 12 GB RAM** (an toàn Free Tier)
3. **Image:** Canonical Ubuntu 22.04
4. **Networking:** dùng VCN mặc định, gán public IP
5. **SSH:** upload public key của bạn (mình giả định `~/.ssh/oci_goshop.pub`)
6. Create → đợi 1-2 phút → ghi lại **Public IP**

> Nếu Oracle báo "Out of capacity": thử region khác (Singapore, Phoenix) hoặc thử lại sau vài giờ — Free A1 thường khan hiếm.

### Step 2 — Mở firewall trên OCI

VCN → Security Lists (hoặc NSG gắn vào VM) → Add Ingress Rules:

| Source | Protocol | Port |
|---|---|---|
| `<IP-admin-của-bạn>/32` | TCP | 22 |
| `0.0.0.0/0` | TCP | 80 |
| `0.0.0.0/0` | TCP | 443 |
| `<IP-admin-của-bạn>/32` | TCP | 6443 |

Tìm IP admin: `curl ifconfig.me`

**Tại sao:** Oracle mặc định chỉ mở port 22. Không mở 80/443 thì cert-manager + ingress sau này không hoạt động.

### Step 3 — Export env vars (mỗi terminal session)

```bash
export VM_IP="<public-ip-bạn-vừa-ghi>"
export VM_USER="ubuntu"
export VM_SSH_KEY="$HOME/.ssh/oci_goshop"
export KUBECONFIG="$HOME/.kube/k3s-goshop.yaml"
```

### Step 4 — Cài k3s trên VM

```bash
./install-k3s.sh
```

Script này sẽ:
1. SCP `vm-install.sh` lên VM
2. SSH chạy nó (truyền `PUBLIC_IP=$VM_IP` để k3s gắn IP vào TLS SAN)
3. `vm-install.sh` trên VM:
   - Tắt swap (k3s yêu cầu)
   - Gỡ `iptables-persistent` (Oracle Ubuntu image cài sẵn rule DROP làm pod-to-pod không kết nối được)
   - Chạy `curl ... | sh` cài k3s với flags: `--disable traefik` (mình dùng ingress-nginx ở Phase 4), `--disable servicelb` (single-node không cần LoadBalancer)
   - Đợi node Ready

**Tại sao disable traefik:** k3s mặc định bundle traefik làm ingress controller. Mình sẽ dùng ingress-nginx ở Phase 4 vì ecosystem rộng + nhiều ví dụ hơn → disable để khỏi xung đột.

**Tại sao disable servicelb (klipper-lb):** Trong cluster đơn node, mình sẽ dùng ingress chạy `hostNetwork` (Phase 4) → không cần LoadBalancer ảo.

### Step 5 — Lấy kubeconfig về máy local

```bash
./fetch-kubeconfig.sh
```

Script này:
1. SSH cat `/etc/rancher/k3s/k3s.yaml` từ VM
2. `sed` đổi `server: https://127.0.0.1:6443` → `server: https://$VM_IP:6443` (để kubectl từ máy local kết nối được)
3. Ghi ra `$KUBECONFIG` với chmod 600

### Step 6 — Verify

```bash
kubectl get nodes
kubectl get pods -A
```

Mong đợi:
- 1 node `Ready`, version `v1.31.x+k3s1` hoặc mới hơn
- Các pod hệ thống (`coredns`, `local-path-provisioner`, `metrics-server`) đều `Running`

## Troubleshooting

| Triệu chứng | Nguyên nhân | Fix |
|---|---|---|
| `kubectl` báo timeout / connection refused | Port 6443 chưa mở ở OCI hoặc IP admin sai | Kiểm tra Security List + `curl ifconfig.me` để xác minh IP |
| `kubectl` báo cert error | `$VM_IP` không có trong TLS SAN | Re-run `install-k3s.sh` (đã truyền `--tls-san $VM_IP`) |
| Node `NotReady` lâu | iptables vẫn DROP | SSH vào VM: `sudo iptables -L INPUT` — nếu thấy DROP, chạy lại `install-k3s.sh` |
| Pod system pending | Hết RAM | `free -h` trên VM; giảm shape về 1 OCPU/6GB không đủ chạy k3s + workload sau |

## Cleanup (nếu muốn làm lại từ đầu)

Trên VM:
```bash
sudo /usr/local/bin/k3s-uninstall.sh
```
Sau đó chạy lại Step 4-6.

Hoặc terminate VM trong OCI và làm lại Step 1.

---

→ **Next:** [Phase 1 — Hello-world](../01-hello-world/)
