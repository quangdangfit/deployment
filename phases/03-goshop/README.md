# Phase 3 — Build & Deploy goshop (BE + FE)

## Mục tiêu

Goshop có **2 phần**:
- **BE** — Go, `cmd/api`, port HTTP 8888 + gRPC 8889
- **FE** — React + Vite + Tailwind ở `web/`, build ra static, serve bằng nginx

Sau phase này:
- Build 2 image multi-arch, push ghcr.io
- BE chạy như **ClusterIP service nội bộ** (không expose ra ngoài)
- FE chạy với nginx, proxy `/api` → BE, expose qua **NodePort 30088**
- Truy cập `http://$VM_IP:30088/` thấy UI React; `/health` hoặc `/api/v1/...` đi qua nginx → BE

```
Internet
   │
   ▼
NodePort 30088
   │
   ▼
[goshop-web pod: nginx]
   ├── /            → static files (React SPA)
   ├── /api/*       → proxy → goshop-api:8888 (BE)
   ├── /health      → proxy → goshop-api:8888/health
   └── /swagger/*   → proxy → goshop-api:8888/swagger/
                                      │
                                      ▼
                                [goshop-api pod: Go]
                                      │
                                      ├──> postgres.data:5432
                                      └──> redis.data:6379
```

## Kiến thức nền

### Tại sao multi-arch?

VM Oracle A1.Flex là **ARM64**. Mặc định `docker build` chỉ build cho kiến trúc máy bạn — sai arch sẽ `exec format error`. Dùng `docker buildx` + QEMU build cả `linux/amd64` + `linux/arm64`.

### Tại sao tách BE thành ClusterIP nội bộ?

- **Bảo mật:** BE không lộ thẳng port ra ngoài; user chỉ tiếp xúc qua FE/nginx.
- **CORS:** FE gọi `/api/*` **cùng origin** với chính nó → không cần CORS preflight.
- **Đơn giản DNS:** chỉ FE cần SSL ở Phase 4; BE giao tiếp qua tên service nội bộ.

### Cách FE đọc API base URL

`vite.config.ts` đã setup proxy dev: `/api → localhost:8888`. Code FE gọi `fetch('/api/...')` (relative). Khi build prod, không có dev server — **nginx** thay vai proxy đó qua `nginx.conf`. Không cần biến môi trường `VITE_API_URL`.

### Cross-namespace Service Discovery

FE nginx ở ns `default` proxy đến BE Service `goshop-api` (cùng ns) — chỉ cần tên service. Pod sau (Postgres ở ns `data`) cần FQDN: `postgres.data` hoặc `postgres.data.svc.cluster.local`.

## Layout file

```
phases/03-goshop/
├── README.md
├── build-and-push.sh           # clone goshop, build BE + FE image, push ghcr.io
├── web/
│   ├── Dockerfile              # multi-stage: node build → nginx serve
│   └── nginx.conf              # SPA fallback + proxy /api → goshop-api
├── manifests/
│   ├── 10-config.yaml          # ConfigMap config.yaml (cho BE)
│   ├── 20-api-deployment.yaml  # BE Deployment
│   ├── 30-api-service.yaml     # BE Service ClusterIP (internal)
│   ├── 40-web-deployment.yaml  # FE Deployment (nginx)
│   └── 50-web-service.yaml     # FE Service NodePort 30088
├── apply.sh
├── verify.sh
└── teardown.sh
```

## Các bước

### Step 1 — Đảm bảo Phase 2 đang chạy

```bash
kubectl -n data get pods   # postgres-0 + redis-... đều Running
```

### Step 2 — Tạo PAT ghcr.io

1. https://github.com/settings/tokens/new?scopes=write:packages,read:packages
2. Generate → copy
3. Export:
   ```bash
   export GHCR_USER=quangdangfit
   export GHCR_TOKEN=ghp_xxx...
   ```

### Step 3 — Build & push 2 image

```bash
./build-and-push.sh
```

Script lần lượt:
1. Clone goshop repo vào `/tmp/goshop-src`
2. Copy `web/Dockerfile` + `web/nginx.conf` vào `/tmp/goshop-src/web/` (goshop repo chưa có)
3. `docker login ghcr.io`
4. Cài QEMU + buildx
5. Build & push **BE** từ `/tmp/goshop-src/` (root, dùng Dockerfile gốc của repo)
6. Build & push **FE** từ `/tmp/goshop-src/web/` (dùng Dockerfile mới copy vào)

Lần đầu ~10 phút (build cả Go + Node trên 2 arch). Lần sau cache layer → ~2-3 phút.

### Step 4 — Đặt CẢ 2 package public

Sau khi push xong, vào package **settings** (URL `/users/...`, KHÔNG phải `/<repo>/pkgs/...` — đó là URL view chỉ có khi package đã link với repo):
- https://github.com/users/quangdangfit/packages/container/goshop/settings → Danger Zone → Change visibility → Public
- https://github.com/users/quangdangfit/packages/container/goshop-web/settings → Danger Zone → Change visibility → Public

Hoặc liệt kê tất cả package: https://github.com/quangdangfit?tab=packages

Quên 1 trong 2 → pod đó sẽ `ImagePullBackOff`.

### Step 5 — Apply manifest

```bash
./apply.sh
```

Script render `GHCR_USER_PLACEHOLDER → $GHCR_USER` trong 2 deployment YAML, rồi `kubectl apply`.

### Step 6 — Smoke test

```bash
# UI React (index.html)
curl -I http://$VM_IP:30088/
# 200 OK, Content-Type: text/html

# Health endpoint (FE nginx proxy đến BE)
curl http://$VM_IP:30088/health
# {"data":null,...}

# Swagger
open http://$VM_IP:30088/swagger/index.html
```

Mở browser `http://$VM_IP:30088/` thấy giao diện goshop.

### Step 7 — Logs khi gặp sự cố

```bash
# Log nginx FE — xem proxy có hit BE không
kubectl logs -l app=goshop-web --tail=50 -f

# Log BE Go
kubectl logs -l app=goshop-api --tail=50 -f
```

## Verify

```bash
./verify.sh
```

Check: 2 deployment Available, 2 service có endpoint, FE `/` = 200, `/health` proxy ok.

## Troubleshooting

| Triệu chứng | Lệnh | Fix |
|---|---|---|
| `ImagePullBackOff` cả 2 pod | `kubectl describe pod ...` | Quên 1 trong 2 package chưa set public |
| FE trả 200 nhưng `/api/*` 502 | `kubectl logs -l app=goshop-web` | nginx upstream "goshop-api" chưa Ready, hoặc BE crash. Check `kubectl get pods -l app=goshop-api` |
| `/api/*` 404 | check route trong code BE | Path BE không có prefix `/api` — đọc kỹ code goshop. Có thể cần sửa nginx.conf bỏ `/api/` prefix khi proxy |
| FE blank trang | DevTools Console | Bundle path sai; xem `vite.config.ts` `base:` |
| Refresh route React → 404 | nginx log | `try_files $uri /index.html` đã có sẵn — verify nginx.conf đã được mount |
| Pod web restart liên tục | `kubectl describe pod -l app=goshop-web` | readinessProbe path sai, hoặc nginx config sai → `kubectl logs ...` |
| `exec format error` | logs | Build thiếu arm64 — verify `--platform linux/amd64,linux/arm64` |
| BE `connection refused` postgres | `kubectl logs -l app=goshop-api` | Phase 2 chưa apply / DNS sai. Test: `kubectl run dnstest --rm -it --image=busybox -- nslookup postgres.data` |

## Cleanup

```bash
./teardown.sh   # xoá BE + FE deployment/service/configmap, GIỮ Phase 2 data
```

---

→ **Next:** [Phase 4 — Ingress + HTTPS](../04-ingress-tls/)
