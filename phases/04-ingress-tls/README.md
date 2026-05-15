# Phase 4 — Ingress + HTTPS (Let's Encrypt)

## Mục tiêu

Thay NodePort `30088` bằng domain thật **`https://goshop.cunghoclaptrinh.online`** với cert hợp lệ từ Let's Encrypt. Sau phase này:
- `ingress-nginx` chạy như reverse proxy (single entry-point cho mọi domain)
- `cert-manager` tự động xin & gia hạn cert TLS
- Browser hiện ổ khóa xanh, không warning

**Đầu ra mong đợi:**
```bash
$ curl -I https://goshop.cunghoclaptrinh.online/health
HTTP/2 200
$ echo | openssl s_client -connect goshop.cunghoclaptrinh.online:443 2>/dev/null \
    | openssl x509 -noout -issuer
issuer=C=US, O=Let's Encrypt, CN=R3
```

## Kiến thức nền

### Helm — package manager cho k8s

Cài cluster-grade software (ingress-nginx, cert-manager, prometheus, …) bằng raw YAML rất khổ: cả trăm resource, hàng ngàn dòng. **Helm chart** = template YAML + file `values.yaml` để cấu hình. Lệnh `helm install` render templates với values rồi `kubectl apply` hết.

```
chart/
├── Chart.yaml         # metadata: name, version, dependencies
├── values.yaml        # default config
└── templates/         # YAML có go template
    ├── deployment.yaml
    └── service.yaml
```

Mình **dùng** chart có sẵn ở phase này. Phase 5 sẽ **viết** chart cho goshop.

### Ingress vs Service

| | Service NodePort (Phase 1, 3) | Ingress |
|---|---|---|
| Layer | L4 (TCP) | L7 (HTTP) |
| Port | 30000-32767 trên mọi node | 80/443 chuẩn |
| Routing | 1 service = 1 port | nhiều domain/path → nhiều service qua 1 port |
| TLS | tự app handle | terminate ở ingress |
| URL | `http://IP:30088` | `https://goshop.domain` |

→ Ingress là cách "production" để expose nhiều service qua 1 IP.

### Ingress Controller vs Ingress Resource

- **Ingress Resource** (YAML): khai báo "request to `goshop.domain` → service `goshop-web:80`"
- **Ingress Controller** (pod thực thi): đọc các Ingress Resource và cấu hình proxy (nginx, traefik, envoy, …). **Phải cài controller**, k8s mặc định không có.

Mình chọn **ingress-nginx** (nginx + Lua) vì:
- Phổ biến nhất, docs/StackOverflow dày
- Ổn định, hiệu năng tốt
- Hỗ trợ tốt cert-manager

### Tại sao hostNetwork DaemonSet trên k3s?

Bình thường ingress-nginx expose qua Service `LoadBalancer` (cloud cấp LB ảo). K3s **không có** LB controller (mình `--disable servicelb`).

→ Giải pháp single-node: chạy ingress-nginx như **DaemonSet với `hostNetwork: true`** → pod chia chung network namespace với node, bind trực tiếp port 80/443 trên VM. Không qua kube-proxy, không cần LB. **Trade-off:** chỉ 1 pod ingress per node (DaemonSet) và port 80/443 trên VM bị "chiếm".

### cert-manager + ACME HTTP-01

**ACME** = giao thức tự động hóa cấp/gia hạn cert (Let's Encrypt). **HTTP-01 challenge:** Let's Encrypt gửi GET đến `http://your-domain/.well-known/acme-challenge/<token>` — bạn phải trả về đúng response để chứng minh sở hữu domain.

cert-manager tự động:
1. Tạo private key
2. Submit CSR đến Let's Encrypt
3. Tạo Ingress tạm để serve `/.well-known/acme-challenge/...`
4. Đợi LE verify
5. Lưu cert vào Secret
6. Gia hạn sau 60 ngày (cert LE dài 90 ngày)

### ClusterIssuer staging vs prod

Let's Encrypt **rate limit nghiêm**: 5 cert/domain/tuần ở prod. Khi debug dễ dính rate limit và phải đợi 1 tuần.

→ Best practice: dùng `letsencrypt-staging` (rate limit cao, cert KHÔNG được trình duyệt tin) để test trước. Hoạt động xong mới chuyển sang `letsencrypt-prod`.

### Cloudflare proxy phải OFF (orange cloud → grey cloud)

Nếu Cloudflare proxy bật, request `.well-known/acme-challenge` sẽ qua Cloudflare → không tới được VM → HTTP-01 fail. Sau khi cert có rồi mới bật lại (Cloudflare sẽ dùng cert của họ với client, cert mình ở backend).

## Layout file

```
phases/04-ingress-tls/
├── README.md
├── install-ingress.sh         # helm install ingress-nginx
├── install-cert-manager.sh    # helm install cert-manager
├── manifests/
│   ├── cluster-issuer-staging.yaml
│   ├── cluster-issuer-prod.yaml
│   └── goshop-ingress.yaml    # Ingress resource cho goshop
├── apply-issuers.sh
├── apply-goshop-ingress.sh
├── verify.sh
└── teardown.sh
```

## Các bước

### Step 1 — Cài Helm trên máy local (nếu chưa)

```bash
brew install helm        # macOS
# hoặc: https://helm.sh/docs/intro/install/
helm version             # cần >= 3.x
```

### Step 2 — Cài ingress-nginx

```bash
./install-ingress.sh
```

Script:
1. `helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx`
2. `helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx` với values inline để chạy hostNetwork DaemonSet
3. Đợi pod Ready

### Step 3 — Mở firewall OCI cho 80/443 (nếu chưa)

Đã làm ở Phase 0 nhưng kiểm tra lại:
```bash
curl -I http://$VM_IP   # nên ra 404 từ nginx (default backend)
```

Nếu timeout → vào OCI Security List add ingress 0.0.0.0/0 cho TCP 80, 443.

### Step 4 — Cài cert-manager

```bash
./install-cert-manager.sh
```

Script:
1. `helm repo add jetstack https://charts.jetstack.io`
2. `helm upgrade --install cert-manager jetstack/cert-manager --set installCRDs=true`
3. Đợi 3 deployment (cert-manager, webhook, cainjector) Ready

### Step 5 — Tạo ClusterIssuer staging & prod

```bash
./apply-issuers.sh
```

Apply 2 ClusterIssuer trỏ tới LE staging + prod, dùng HTTP-01 solver với ingress class `nginx`.

```bash
kubectl get clusterissuer
# Mong đợi: cả 2 READY=True trong ~30s
```

### Step 6 — Trỏ DNS Cloudflare

Trong Cloudflare dashboard, thêm A record:
- Name: `goshop` (= subdomain `goshop.cunghoclaptrinh.online`)
- IPv4: `$VM_IP`
- Proxy status: **DNS only** (grey cloud) — quan trọng cho HTTP-01

Đợi propagate (~1 phút). Verify:
```bash
dig +short goshop.cunghoclaptrinh.online
# Phải ra $VM_IP
```

### Step 7 — Đảm bảo goshop đã chạy (Phase 3)

```bash
kubectl -n default get svc goshop-web
# Nếu chưa: quay lại Phase 3
```

### Step 8 — Apply Ingress cho goshop (prod issuer)

`manifests/goshop-ingress.yaml` đã set sẵn `cluster-issuer: letsencrypt-prod`.

> **Cảnh báo rate limit:** Let's Encrypt prod giới hạn **5 cert/domain/tuần**. Nếu apply nhiều lần do cấu hình sai (DNS chưa propagate, Cloudflare proxy còn ON, ingress-nginx chưa Ready), bạn sẽ dính rate limit và phải đợi 1 tuần. Trước khi chạy, **double-check**:
> - `dig +short goshop.cunghoclaptrinh.online` trả về đúng `$VM_IP`
> - Cloudflare proxy = **DNS only** (grey cloud)
> - `curl -I http://goshop.cunghoclaptrinh.online` trả 404 từ nginx (ingress đã bắt được host)
>
> Nếu lo lắng / chưa chắc: tạm dùng `cluster-issuer: letsencrypt-staging` để debug (cert không hợp lệ với browser nhưng rate limit cao), khi OK đổi sang `letsencrypt-prod`.

```bash
./apply-goshop-ingress.sh
```

Theo dõi:
```bash
kubectl -n default get certificate
kubectl -n default describe certificate goshop-tls
# Đợi Ready=True (~30-90s)

# Nếu stuck, xem challenge:
kubectl -n default get challenge
kubectl -n default describe challenge
```

Verify HTTPS:
```bash
curl -I https://goshop.cunghoclaptrinh.online/health
# HTTP/2 200, không cần -k
```

Inspect cert chain:
```bash
echo | openssl s_client -connect goshop.cunghoclaptrinh.online:443 2>/dev/null \
  | openssl x509 -noout -issuer -subject -dates
# issuer phải chứa "Let's Encrypt", KHÔNG có "STAGING"
```

### Step 9 — Bật lại Cloudflare proxy (optional)

Sau khi prod cert có, bạn có thể bật orange cloud nếu muốn benefit Cloudflare (DDoS, caching, …). Cert vẫn ổn vì traffic Cloudflare→VM vẫn HTTPS đến ingress.

## Verify

```bash
./verify.sh
```

Check:
- Pod ingress-nginx + cert-manager Running
- ClusterIssuer Ready
- Cert `goshop-tls` Ready=True
- `https://goshop.domain/health` trả 200 với cert hợp lệ

## Troubleshooting

| Triệu chứng | Lệnh | Fix |
|---|---|---|
| Certificate stuck `False` | `kubectl -n default describe challenge` | Thường: Cloudflare proxy ON, hoặc DNS chưa propagate, hoặc port 80 chưa mở |
| `acme: error: 429: ... rate limit` | (log cert-manager) | Bị rate limit prod. Đợi 1 tuần hoặc dùng staging |
| `connection refused` khi curl :80 | `kubectl -n ingress-nginx get pod -o wide` + `ssh ... ss -tlnp \| grep :80` | hostNetwork không bind. Xác minh DaemonSet pod Ready trên node |
| `404 default backend` khi curl đúng domain | `kubectl -n default describe ingress goshop` | host/path không khớp, hoặc service backend sai tên |
| Browser warning về cert | `openssl s_client ...` | Có thể cert vẫn staging — đảm bảo đã chuyển sang `letsencrypt-prod` |

## Cleanup

```bash
./teardown.sh
```

Xóa Ingress goshop + ClusterIssuer. KHÔNG uninstall ingress-nginx/cert-manager (Phase 6 vẫn cần). Nếu muốn xóa hết:
```bash
helm -n ingress-nginx uninstall ingress-nginx
helm -n cert-manager uninstall cert-manager
kubectl delete ns ingress-nginx cert-manager
```

---

→ **Next:** [Phase 5 — Helm chart cho goshop](../05-helm/)
