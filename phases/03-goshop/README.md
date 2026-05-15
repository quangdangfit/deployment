# Phase 3 — Build & Deploy goshop

## Mục tiêu

Build image goshop **multi-arch** (amd64 + arm64), push lên ghcr.io, deploy lên k8s, kết nối với Postgres + Redis từ Phase 2. Truy cập qua `http://$VM_IP:30088/healthz`.

CHƯA có domain/HTTPS — đó là Phase 4.

**Đầu ra mong đợi:**
```bash
$ curl http://$VM_IP:30088/healthz
{"status":"ok"}   # hoặc tương đương
```

## Kiến thức nền

### Tại sao multi-arch?

VM Oracle A1.Flex là **ARM64** (Ampere). Mặc định `docker build` chỉ build cho kiến trúc của máy bạn (vd macOS Intel = amd64, Apple Silicon = arm64). Nếu build sai arch, k3s sẽ báo `exec format error` khi chạy.

→ Dùng `docker buildx` + QEMU emulation để build cả 2 arch trong 1 lệnh.

### Container registry: ghcr.io

- GitHub Container Registry, free cho repo public
- Auth bằng GitHub Personal Access Token (PAT) với scope `write:packages` HOẶC `GITHUB_TOKEN` trong CI
- Image path: `ghcr.io/<user>/<repo>:<tag>`

Phase này **build local + push thủ công** để bạn hiểu pipeline. Phase 8 tự động hóa bằng GitHub Actions.

### ConfigMap để chứa config.yaml

goshop load file `config.yaml` từ working directory (override `CONFIG_FILE=...`). Mình:
1. Render config.yaml với DSN/Redis URL trỏ đến Service ở namespace `data`
2. Đưa vào ConfigMap
3. Mount thành file `/app/config.yaml` trong pod

Phần secrets (auth_secret, stripe keys) cũng nhúng vào file này — Phase 7 sẽ tách secrets ra Secret/ExternalSecret.

### Service Discovery cross-namespace

Pod ở ns `goshop` muốn gọi Service ở ns `data`:
```
postgres.data.svc.cluster.local   # FQDN
postgres.data                     # short form, cũng được
```

Trong cùng ns: chỉ cần `postgres`.

### Cách app discover DB qua DNS

Khi pod start, CoreDNS resolve `postgres.data` → ClusterIP của Service → kube-proxy NAT đến pod IP. Pod tự khám phá, không cần hardcode IP.

## Layout file

```
phases/03-goshop/
├── README.md
├── build-and-push.sh       # clone goshop → buildx → push ghcr.io
├── manifests/
│   ├── 00-namespace.yaml
│   ├── 10-config.yaml      # ConfigMap chứa config.yaml
│   ├── 20-deployment.yaml
│   └── 30-service.yaml
├── apply.sh
├── verify.sh
└── teardown.sh
```

## Các bước

### Step 1 — Đảm bảo Phase 2 đang chạy

```bash
kubectl -n data get pods   # postgres-0 + redis-... đều Running
```

Nếu chưa, quay lại Phase 2.

### Step 2 — Tạo Personal Access Token (PAT) cho ghcr.io

1. Vào https://github.com/settings/tokens/new?scopes=write:packages,read:packages
2. Note: `ghcr-push`
3. Expiration: 90 days (hoặc tuỳ)
4. Generate → copy token (`ghp_xxx...`)
5. Export:
   ```bash
   export GHCR_USER=quangdangfit
   export GHCR_TOKEN=ghp_xxx...
   ```

> Lưu token vào password manager. Mất là phải tạo lại.

### Step 3 — Build & push image

```bash
./build-and-push.sh
```

Script này:
1. Clone (hoặc pull) `quangdangfit/goshop` vào `/tmp/goshop-src`
2. `docker login ghcr.io -u $GHCR_USER -p $GHCR_TOKEN`
3. `docker buildx create --use --name multi-arch` (nếu chưa có)
4. Cài QEMU emulator: `docker run --rm --privileged tonistiigi/binfmt --install all`
5. `docker buildx build --platform linux/amd64,linux/arm64 --tag ghcr.io/$GHCR_USER/goshop:phase3 --push .`

Lần đầu mất 5-10 phút (compile + emulation ARM). Lần sau cache Docker layer thường <2 phút nếu Dockerfile không thay đổi.

### Step 4 — Đặt image package public

Image vừa push **mặc định private** → k3s không pull được.

1. Vào https://github.com/quangdangfit/goshop/pkgs/container/goshop
2. Package settings (cuối trang bên phải) → Change visibility → Public

> Nếu muốn giữ private: phải tạo `imagePullSecret` trong namespace `goshop` và tham chiếu trong `spec.imagePullSecrets`. Để đơn giản: chọn public.

### Step 5 — Render config + apply manifest

```bash
./apply.sh
```

Script này:
1. Tạo ns `goshop`
2. Apply ConfigMap (config.yaml đã trỏ sẵn vào `postgres.data` và `redis.data`)
3. Apply Deployment với image `ghcr.io/$GHCR_USER/goshop:phase3`
4. Apply Service NodePort 30088
5. Đợi rollout

### Step 6 — Smoke test

```bash
# Health check qua NodePort:
curl http://$VM_IP:30088/healthz

# Hoặc port-forward để test mà không cần mở port OCI:
kubectl -n goshop port-forward svc/goshop 8888:8888
# Tab khác:
curl http://localhost:8888/healthz
```

Nếu app có Swagger:
```
http://$VM_IP:30088/swagger/index.html
```

### Step 7 — Kiểm tra logs

```bash
kubectl -n goshop logs -l app=goshop --tail=50 -f
```

Nếu thấy error kết nối DB, vào Troubleshooting bên dưới.

## Verify

```bash
./verify.sh
```

## Troubleshooting

| Triệu chứng | Lệnh | Fix |
|---|---|---|
| `ImagePullBackOff` | `kubectl -n goshop describe pod <pod>` | Image vẫn private (Step 4) hoặc tag không tồn tại |
| `exec format error` trong log | `kubectl -n goshop logs ...` | Build thiếu arm64 → build lại với `--platform linux/amd64,linux/arm64` |
| `connection refused` đến postgres | `kubectl -n goshop logs ...` + `kubectl -n data get svc postgres` | Phase 2 chưa apply hoặc DNS sai. Test: `kubectl -n goshop run dnstest --rm -it --image=busybox -- nslookup postgres.data` |
| `password authentication failed` | logs | Mật khẩu trong ConfigMap không khớp Secret ở Phase 2 (`goshop_dev`) |
| App start ok nhưng `/healthz` 404 | `curl ... -v` | Đường dẫn health endpoint khác; thử `/`, `/health`, hoặc `/api/v1/health` |
| Pod restart liên tục | `kubectl -n goshop describe pod ...` (Events) | livenessProbe quá khắt khe → tăng `initialDelaySeconds` |
| Migration cần chạy thủ công | `kubectl -n goshop logs ... | grep -i migrat` | Goshop hiện auto-migrate qua GORM khi start, không cần Job riêng. Nếu lỗi, kiểm tra schema trong DB |

## Cleanup

```bash
./teardown.sh   # xoá ns goshop, GIỮ Phase 2 data
```

---

→ **Next:** [Phase 4 — Ingress + HTTPS](../04-ingress-tls/)
