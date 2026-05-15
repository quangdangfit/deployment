# Doppler Setup (manual UI)

## Step 1 — Tạo account

https://doppler.com → Sign up (free, 3 user/seats).

## Step 2 — Tạo project + config

1. Workplace → **Projects** → **New Project** → `goshop`
2. Mặc định sinh 3 config: `dev`, `stg`, `prd`. Để nguyên hoặc xóa cái không dùng.

## Step 3 — Thêm secrets vào config `prd`

Click `prd` → Add secret. Các key cần (tên phải khớp ExternalSecret manifest):

| Key | Cách sinh giá trị |
|---|---|
| `POSTGRES_ADMIN_PASSWORD` | `openssl rand -base64 24` (loại bỏ `/`, `+`, `=` cho an toàn) |
| `POSTGRES_PASSWORD` | giống trên (user `goshop`) |
| `REDIS_PASSWORD` | `openssl rand -hex 16` |
| `AUTH_SECRET` | `openssl rand -hex 32` (JWT signing key) |
| `STRIPE_SECRET_KEY` | từ Stripe dashboard → API keys |
| `STRIPE_WEBHOOK_SECRET` | từ Stripe → Webhooks |
| `STRIPE_PUBLISHABLE_KEY` | từ Stripe |
| `SMTP_USER` | tùy provider (SendGrid, SES, …) |
| `SMTP_PASSWORD` | tùy provider |

> Tip: dùng password manager (1Password, Bitwarden) phụ trợ để lưu backup khi cần debug.

## Step 4 — Tạo Service Token

Vào `prd` config → **Access** → **Service Tokens** → **Generate**:
- Name: `k8s-eso-prd`
- Access: `Read`
- Expiration: không hết hạn (hoặc 90/180 ngày tùy chính sách)

Copy token (`dp.st.prd.xxxxxxxxxxxx`). **Chỉ hiện 1 lần.**

```bash
export DOPPLER_TOKEN=dp.st.prd.xxxxxxxxxxxx
```

## Step 5 — Verify bằng CLI (optional)

```bash
brew install dopplerhq/cli/doppler         # macOS
doppler configure set token "$DOPPLER_TOKEN"
doppler secrets get POSTGRES_PASSWORD --project goshop --config prd --plain
# Phải in ra giá trị bạn vừa nhập
```

## Best practices

- **Mỗi cluster/env một token riêng.** Nếu prd cluster compromise, dev/stg không bị.
- **Audit log:** Doppler có activity log — review định kỳ.
- **Rotate token** mỗi 90 ngày: tạo token mới → update Secret `doppler-token` → revoke token cũ.
- **Sync history:** Doppler giữ history mỗi lần secret đổi → restore được nếu lỡ tay.
