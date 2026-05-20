# Zitadel IdP cho Goshop — Design

Date: 2026-05-20
Status: Approved (pending implementation plan)
Supersedes: `2026-05-19-authentik-goshop-design.md`

## 1. Mục tiêu & phạm vi

Thay thế Authentik (đã deploy nhưng chưa có user thật) bằng **Zitadel self-hosted** trên K3s, làm IdP duy nhất cho Goshop B2C. Authentik sẽ được gỡ hoàn toàn sau khi Zitadel hoạt động.

Zitadel chịu trách nhiệm:
- Authentication (username/password, social Google + Facebook)
- Self-service register + email verification
- Forgot password / reset qua email
- Phát hành OIDC token (Authorization Code + PKCE)
- Custom branding (logo, màu, login page Goshop)

**Scope của spec này** giới hạn trong repo `deployment`: cài đặt, deploy, cấu hình Zitadel. Tích hợp `goshop-api` / `goshop-web` (đổi issuer URL, client credentials, parse roles claim) do session khác xử lý trên repo goshop — spec này chỉ bàn giao `client_id`/`client_secret` + issuer URL qua Doppler.

**Out of scope:** MFA, passkeys, multi-tenant (organizations), automation cấu hình bằng Terraform / zitadel-tools, migration user từ Authentik (chưa có user thật).

## 2. Kiến trúc tổng quan

- **Namespace:** `auth` (dùng lại của Authentik sau khi gỡ).
- **Helm chart:** `zitadel/zitadel`, quản lý qua **ArgoCD Application**.
- **Database:** Postgres dùng chung trong namespace `data`. DB `zitadel` + user `zitadel` riêng.
- **Redis:** không cần (Zitadel không phụ thuộc Redis, khác Authentik).
- **Ingress:** `auth.cunghoclaptrinh.online`, TLS qua cert-manager + `letsencrypt-prod`, ingress-nginx. Zitadel chạy gRPC + HTTP cùng port 8080 (h2c) → cần annotation `nginx.ingress.kubernetes.io/backend-protocol: "GRPC"`.
- **Secrets:** Doppler ExternalSecret (`apps/zitadel/externalsecret.yaml`).
- **Email:** SMTP **Resend** (free 3k/tháng). API key trong Doppler.

### Sơ đồ luồng

```
Browser ─► goshop-web ─► /api ─► goshop-api
   │                                  │
   │  OIDC AuthCode + PKCE            │  JWKS / token
   ▼                                  ▼
auth.cunghoclaptrinh.online (Zitadel)
```

## 3. File layout

```
apps/zitadel/
  application.yaml      # ArgoCD Application, sync wave sau platform
  namespace.yaml        # namespace auth (giữ lại / tạo mới sau khi gỡ authentik)
  values.yaml           # Helm values cho zitadel/zitadel
  externalsecret.yaml   # Doppler → secret zitadel-secrets
```

## 4. Helm values (key items)

```yaml
zitadel:
  masterkey: <from secret>            # 32 ký tự, encrypt internal data
  configmapConfig:
    ExternalDomain: auth.cunghoclaptrinh.online
    ExternalPort: 443
    ExternalSecure: true
    TLS:
      Enabled: false                  # TLS terminate ở ingress
    Database:
      Postgres:
        Host: postgres.data.svc.cluster.local
        Port: 5432
        Database: zitadel
        User:
          Username: zitadel
          SSL: { Mode: disable }
        Admin:
          Username: zitadel           # dùng chính user app, không cần superuser
          SSL: { Mode: disable }
    FirstInstance:
      Org:
        Human:
          UserName: admin
          Email: { Address: <admin email>, Verified: true }
    DefaultInstance:
      SMTPConfiguration:
        SMTP:
          Host: smtp.resend.com:465
          User: resend
        From: noreply@<your-domain>
        FromName: Goshop
        TLS: true
  dbSslRootCrtSecret: ""

replicaCount: 1

ingress:
  enabled: true
  className: nginx
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
    nginx.ingress.kubernetes.io/backend-protocol: "GRPC"
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
  hosts:
    - host: auth.cunghoclaptrinh.online
      paths: [{ path: /, pathType: Prefix }]
  tls:
    - hosts: [auth.cunghoclaptrinh.online]
      secretName: zitadel-tls

resources:
  requests: { cpu: 100m, memory: 256Mi }
  limits:   { cpu: 500m, memory: 512Mi }
```

## 5. Secrets (Doppler keys)

- `ZITADEL_MASTERKEY` — 32-char random. **Không được đổi** sau khi cài; mất key = mất khả năng decrypt data.
- `ZITADEL_DB_PASSWORD` — password user `zitadel` trong Postgres.
- `ZITADEL_ADMIN_PASSWORD` — bootstrap admin lần đầu.
- `ZITADEL_SMTP_PASSWORD` — Resend API key (dùng làm SMTP password).
- `GOSHOP_OIDC_CLIENT_ID` / `GOSHOP_OIDC_CLIENT_SECRET` — tạo sau khi Zitadel chạy + cấu hình app; overwrite key cũ từ Authentik.

## 6. Postgres bootstrap (manual one-shot)

```sql
CREATE USER zitadel WITH PASSWORD '<from doppler>';
CREATE DATABASE zitadel OWNER zitadel;
GRANT ALL PRIVILEGES ON DATABASE zitadel TO zitadel;
```

## 7. Cấu hình Zitadel post-install (Console UI)

Login `https://auth.cunghoclaptrinh.online` bằng admin + bootstrap password.

1. **Org & Project**
   - Rename default org → `Goshop`.
   - Tạo Project `goshop`.

2. **OIDC Application** (trong project goshop)
   - Name: `goshop-web`
   - Type: Web
   - Auth method: Code (Authorization Code + PKCE)
   - Redirect URI: `https://goshop.cunghoclaptrinh.online/api/v1/auth/callback`
   - Post-logout URI: `https://goshop.cunghoclaptrinh.online/`
   - Token type: **JWT** (goshop-api verify offline qua JWKS).
   - Lưu `client_id` + `client_secret` → Doppler keys `GOSHOP_OIDC_CLIENT_ID/SECRET`.

3. **Login Policy (B2C self-service)**
   - Register allowed: on
   - Password reset allowed: on
   - Force email verification: on
   - Username = email

4. **Identity Providers (social login)**
   - **Google**: tạo OAuth client tại Google Cloud Console → paste credentials → enable.
   - **Facebook**: tạo app tại Meta Developer → paste credentials → enable.
   - Redirect URI Zitadel cung cấp: `https://auth.cunghoclaptrinh.online/ui/login/login/externalidp/callback`.

5. **Branding**
   - Settings → Branding: logo Goshop, primary color, font.
   - Apply cho default instance.

6. **SMTP test**
   - Settings → SMTP: verify gửi mail test qua Resend.

7. **Custom claim cho RBAC**
   - Project → Roles: tạo `admin`, `user`.
   - Authorizations: gán role cho user.
   - Application → Token settings: bật **User roles inside ID Token** + **User Info inside ID Token** → claim `urn:zitadel:iam:org:project:roles`.

Tự động hóa các bước này bằng zitadel-tools / Terraform: out of scope.

## 8. Tích hợp goshop-api / goshop-web (handover)

Spec này không thay đổi code goshop. Session khác phụ trách. Bàn giao gồm:

- Issuer URL: `https://auth.cunghoclaptrinh.online`
- Discovery: `https://auth.cunghoclaptrinh.online/.well-known/openid-configuration`
- JWKS: `https://auth.cunghoclaptrinh.online/oauth/v2/keys`
- Scopes cần request: `openid profile email offline_access urn:zitadel:iam:org:project:roles`
- Roles claim format khác Authentik (`urn:zitadel:iam:org:project:roles` = map `{ "<role>": { "<orgId>": "<orgDomain>" } }`) — cần helper parse riêng.
- `GOSHOP_OIDC_CLIENT_ID/SECRET` trong Doppler được overwrite bằng giá trị từ Zitadel.

## 9. Rollout plan

1. **Gỡ Authentik**: xóa ArgoCD Application `authentik`, đợi resources clean. Drop DB `authentik` + user (manual psql).
2. **Bootstrap Postgres cho Zitadel**: tạo user + DB `zitadel` (manual psql).
3. **Seed Doppler secrets** (Section 5): masterkey, db password, admin password, SMTP key.
4. **Apply `apps/zitadel/`**: namespace, externalsecret, ArgoCD Application. Sync. Đợi pod ready + ingress TLS cấp.
5. **Verify**: truy cập `https://auth.cunghoclaptrinh.online`, login admin, đổi password.
6. **Cấu hình Console** (Section 7): project + OIDC app + login policy + Google/Facebook IdP + branding + SMTP test.
7. **Bàn giao credentials** cho session goshop: lưu `GOSHOP_OIDC_CLIENT_ID/SECRET` vào Doppler.
8. **Cleanup** sau khi goshop chạy ổn ≥ 1 tuần: xóa `apps/authentik/` khỏi repo + xóa `AUTHENTIK_*` keys trong Doppler.

## 10. Risks & mitigations

- **Postgres dùng chung**: connection limit cho user `zitadel`, DB riêng. Theo dõi metrics.
- **Mất masterkey** = mất decrypt data. Lưu Doppler + backup offline.
- **gRPC ingress h2c**: nginx-ingress cần annotation đúng; có thể cần debug khi sync lần đầu (kiểm tra `kubectl logs` của controller + thử curl `/.well-known/openid-configuration`).
- **Resend dependency**: nếu Resend hỏng, email verify/reset không gửi được → fallback: tạm thời tắt force email verification, hoặc đổi sang SMTP khác qua Console.
- **Authentik down trong lúc cutover**: chấp nhận, vì chưa có user thật.

## 11. Open questions (resolve trong writing-plans)

- Postgres user `zitadel` có cần quyền `CREATE EXTENSION` hay schema-level grant nào không (Zitadel tự migrate)? Tra docs Zitadel chính thức trong plan.
- Annotation chính xác cho ingress-nginx khi backend là h2c gRPC + HTTP UI cùng port — có cần tách 2 ingress object không?
- Resend domain verification (SPF/DKIM) — có sẵn DNS cho `<your-domain>` chưa?
