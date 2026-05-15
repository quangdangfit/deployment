# Phase 7 — Doppler + External Secrets Operator (ESO)

## Mục tiêu

Từ Phase 2-6, mật khẩu DB / Redis / JWT secret / Stripe keys nằm thẳng trong YAML hoặc values.yaml — commit vào git. Cấm với production.

Phase này:
- Tách mọi secret ra khỏi git
- Lưu ở **Doppler** (SaaS secret manager, free tier rộng)
- ESO tự sync Doppler → Kubernetes Secret
- App tham chiếu Secret như bình thường, không biết Doppler tồn tại

**Đầu ra mong đợi:**
```bash
$ kubectl -n default get externalsecret
NAME            STORE      REFRESH INTERVAL   STATUS         READY
goshop-secrets  doppler    1h                 SecretSynced   True

$ kubectl -n default get secret goshop-secrets
# Tự động sinh, KHÔNG nằm trong git
```

## Kiến thức nền

### Tại sao không hardcode secret trong git?

| Rủi ro | Hậu quả |
|---|---|
| Repo public hoặc rò rỉ | Mất DB password, ai cũng đăng nhập được |
| Commit lịch sử forever | `git rm` không xóa được — phải rewrite history |
| Multi-env trộn secret | dev/staging/prod dùng chung dễ nhầm |
| Audit/compliance | SOC2, ISO 27001 yêu cầu secret encrypted at rest, KMS-backed |

### Các phương án

| Phương án | Mô tả | Ưu | Nhược |
|---|---|---|---|
| **Sealed Secrets** | Encrypt secret bằng public key của controller, commit ciphertext vào git | Free, GitOps-native | Mất master key = mất hết; xoay key khó |
| **HashiCorp Vault** | Self-hosted secret manager | Mạnh nhất, dynamic credentials | Vận hành tốn công |
| **AWS/GCP Secrets Manager** | Cloud-managed | Tích hợp IAM | Vendor lock-in, không free |
| **Doppler** | SaaS, simple UI, free 3-user | Setup nhanh, web UI tốt | SaaS bên thứ 3 (downtime = không sync được) |
| **1Password / Bitwarden** | Tích hợp ESO qua provider | Đã có cho team | Latency cao hơn |

Mình chọn **Doppler** vì free + setup nhanh + có ESO provider sẵn. Nếu dùng option khác, thay `provider:` trong `ClusterSecretStore` — phần còn lại của ESO giống nhau.

### External Secrets Operator (ESO)

```
┌─────────────────────────────────────────────────────────────────┐
│ Cluster                                                          │
│                                                                  │
│   ExternalSecret ──watched by──> ESO controller                  │
│        │                              │                          │
│        │ định nghĩa                   │ poll từ                  │
│        ▼                              ▼                          │
│   refreshInterval, key map ──> ClusterSecretStore                │
│                                       │                          │
│                                       │ HTTPS                    │
│                                       ▼                          │
│                                  Doppler API ──> [Doppler cloud] │
│                                                                  │
│   Khi sync xong:                                                 │
│   ExternalSecret ──creates──> native Secret (Opaque)             │
│                                       │                          │
│                                       │ envFrom/volumeMount      │
│                                       ▼                          │
│                                      Pod                         │
└──────────────────────────────────────────────────────────────────┘
```

Các CRD chính:
- `SecretStore` (ns-scoped) / `ClusterSecretStore` (cluster-scoped): nói "lấy secret từ đâu, auth thế nào"
- `ExternalSecret`: nói "tôi muốn key X từ store Y, map thành Secret tên Z"
- `PushSecret`: chiều ngược lại (ít dùng)

### Doppler concepts

```
Project (vd: goshop)
└── Config (vd: dev, staging, prod)
    └── Secrets (KEY=VALUE pairs)
```

- **Service token:** auth read-only cho 1 config (vd `prd_xxx` cho prod). Đây là cái ta nhúng vào k8s Secret để ESO dùng.

## Layout file

```
phases/07-doppler-eso/
├── README.md
├── doppler-setup.md            # hướng dẫn tạo project/config/secrets trên UI
├── install-eso.sh
├── manifests/
│   ├── cluster-secret-store.yaml   # ClusterSecretStore "doppler"
│   ├── data-externalsecrets.yaml   # postgres-credentials, redis-credentials (Phase 2)
│   └── goshop-externalsecret.yaml  # goshop-secrets (Phase 5)
├── apply.sh
├── verify.sh
└── teardown.sh
```

## Các bước

### Step 1 — Setup Doppler

Đọc `doppler-setup.md`. Tóm tắt:
1. Tạo account ở doppler.com (free)
2. Project: `goshop` → Config: `prd` (hoặc `dev` tuỳ ý)
3. Add các keys:
   ```
   POSTGRES_ADMIN_PASSWORD = <generated strong password>
   POSTGRES_PASSWORD       = <generated>
   REDIS_PASSWORD          = <generated>
   AUTH_SECRET             = <openssl rand -hex 32>
   STRIPE_SECRET_KEY       = sk_test_...
   STRIPE_WEBHOOK_SECRET   = whsec_...
   STRIPE_PUBLISHABLE_KEY  = pk_test_...
   SMTP_USER               = ...
   SMTP_PASSWORD           = ...
   ```
4. Access → tạo Service Token → copy (vd `dp.st.prd.xxx`)

### Step 2 — Cài ESO

```bash
./install-eso.sh
```

Helm cài chart `external-secrets/external-secrets` (version 2.4.x — sau khi project tái bản version từ 0.x → 2.x cuối 2025).

### Step 3 — Seed Doppler token vào cluster

```bash
export DOPPLER_TOKEN=dp.st.prd.xxx
kubectl create ns external-secrets --dry-run=client -o yaml | kubectl apply -f -
kubectl -n external-secrets create secret generic doppler-token \
  --from-literal=dopplerToken="$DOPPLER_TOKEN" \
  --dry-run=client -o yaml | kubectl apply -f -
```

→ Đây là secret DUY NHẤT cần tạo bằng `kubectl` thay vì qua ESO (vì ESO cần token này để auth). Bootstrap problem.

### Step 4 — Apply ClusterSecretStore + ExternalSecrets

```bash
./apply.sh
```

Apply:
- `cluster-secret-store.yaml` → ESO biết Doppler ở đâu
- `data-externalsecrets.yaml` → sync `POSTGRES_*` / `REDIS_*` thành Secret `postgres-credentials`, `redis-credentials` ở ns `data`
- `goshop-externalsecret.yaml` → sync `AUTH_SECRET`, `STRIPE_*`, `SMTP_*` thành Secret `goshop-secrets` ở ns `goshop`

Verify:
```bash
kubectl get clustersecretstore
kubectl -n data get externalsecret,secret
kubectl -n default get externalsecret,secret
```

Mong đợi: ExternalSecret `Ready=True`, Secret tương ứng đã tồn tại.

### Step 5 — Migrate Phase 2 (data) sang dùng ExternalSecret

Phase 2 hardcode `POSTGRES_PASSWORD: goshop_dev` trong `10-secret.yaml`. Giờ:

```bash
# Xóa Secret cũ hardcode:
kubectl -n data delete secret postgres-credentials redis-credentials
```

→ ESO sẽ tạo lại 2 Secret này từ Doppler (cần khác password với cũ). Pod postgres-0 đang chạy với password CŨ trong env — đây là vấn đề:

**Quan trọng:** đổi password Postgres không tự magic. 2 lựa chọn:

(a) **Reset từ đầu (dev):** xóa ns `data` (mất data) → apply lại với ExternalSecret + Doppler value làm initial password.

(b) **Migrate sống (prod):** exec vào pod postgres `ALTER USER goshop PASSWORD '<new>'` đúng giá trị Doppler, rồi delete pod (sts respawn với env mới).

Phase này (học) → khuyên (a). Trong production tài liệu rõ trong runbook.

### Step 6 — Migrate Phase 5 (goshop chart) sang đọc Secret

Edit `phases/05-helm/chart/goshop/templates/deployment.yaml` — thêm `envFrom` lấy từ Secret `goshop-secrets`, và **bỏ** các trường secret khỏi `configmap.yaml`:

```yaml
# deployment.yaml — thêm:
spec:
  template:
    spec:
      containers:
        - name: goshop
          envFrom:
            - secretRef:
                name: goshop-secrets    # AUTH_SECRET, STRIPE_*, SMTP_*
```

Và sửa code goshop để đọc các giá trị này từ env (nếu chưa). Goshop có thể đã hỗ trợ ENV override qua viper — đọc code `cmd/api` để xác nhận.

**Tạm thời (nếu app không support env):** giữ config.yaml render từ ConfigMap, NHƯNG thay giá trị thành placeholder và dùng init container `envsubst` để substitute trước khi app start. Đây là pattern xấu — ưu tiên sửa code app dùng env.

### Step 7 — Verify end-to-end

```bash
./verify.sh
```

Kiểm tra:
- ESO controller pod Running
- ClusterSecretStore `Valid=True`
- ExternalSecret `Ready=True`
- Secret hardcode đã không còn (chỉ có secret do ESO tạo)
- App vẫn truy cập được https://goshop.domain/healthz

## Troubleshooting

| Triệu chứng | Lệnh | Fix |
|---|---|---|
| ExternalSecret `SecretSyncedError` | `kubectl describe externalsecret ...` | Sai key Doppler hoặc token expired |
| ClusterSecretStore `not Valid` | `kubectl describe clustersecretstore doppler` | Token Secret sai ns/key |
| ESO pod CrashLoop | `kubectl -n external-secrets logs ...` | Thường CRD/chart version mismatch — đọc kỹ Phase plan |
| Sau xóa Secret cũ, pod auth fail | `kubectl logs ...` | Password DB không khớp giá trị Doppler — xem Step 5 |
| Token rò rỉ | n/a | Vào Doppler → Access → Revoke token → tạo mới → update k8s Secret |

## Cleanup

```bash
./teardown.sh
```

Xóa ExternalSecret + ClusterSecretStore + ESO. **Không** xóa secret `doppler-token` (giữ token để dùng lại). Để xóa hẳn: `kubectl -n external-secrets delete secret doppler-token`.

---

→ **Next:** [Phase 8 — CI/CD build image](../08-cicd/)
