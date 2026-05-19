# Authentik AuthN/Z cho Goshop — Design

Date: 2026-05-19
Status: Approved (pending implementation plan)

## 1. Mục tiêu

Triển khai Authentik làm IdP duy nhất cho Goshop, thay thế hoàn toàn cơ chế login/register hiện tại trong `goshop-api`. Authentik chịu trách nhiệm authentication, quản lý user/group, và phát hành OIDC token; `goshop-api` chỉ verify token và áp dụng RBAC dựa trên claims.

## 2. Kiến trúc tổng quan

- Namespace mới: `auth`.
- Triển khai qua **Helm chart `goauthentik/authentik`**, quản lý bằng **ArgoCD Application** (`apps/authentik/application.yaml`), values ở `apps/authentik/values.yaml` — đồng nhất pattern hiện tại trong repo.
- Expose qua **ingress-nginx** tại `auth.cunghoclaptrinh.online`, TLS do **cert-manager** cấp với `clusterIssuer: letsencrypt-prod`.
- **Postgres**: dùng lại cluster Postgres trong namespace `data`. Tạo database `authentik` và user riêng `authentik`.
- **Redis**: deploy Redis **riêng** trong namespace `auth` (subchart của Helm chart Authentik, mặc định bật) — tách biệt blast radius khỏi Redis dùng chung khác.
- **Secrets**: qua Doppler ExternalSecret (đồng nhất với pattern goshop-api/databases), file `apps/authentik/externalsecret.yaml`.

### Sơ đồ luồng

```
Browser ──► goshop-web (nginx) ──► /api ──► goshop-api
   │                                            │
   │  OIDC redirect (Authorization Code + PKCE) │
   ▼                                            ▼
auth.cunghoclaptrinh.online (Authentik) ◄── JWKS / token endpoint
```

## 3. Triển khai Authentik

### 3.1 File layout

```
apps/authentik/
  application.yaml         # ArgoCD Application, sync wave sau platform
  namespace.yaml           # namespace: auth
  values.yaml              # Helm values cho goauthentik/authentik
  externalsecret.yaml      # Doppler → secret authentik-secrets
```

### 3.2 Helm values (key items)

- `authentik.secret_key`: từ secret `authentik-secrets`.
- `authentik.postgresql.host`: service Postgres trong namespace `data` (DNS `postgres.data.svc.cluster.local`).
- `authentik.postgresql.user`: `authentik`, `password` từ secret, `name`: `authentik`.
- `authentik.redis.host`: Redis subchart (mặc định `<release>-redis-master`).
- `postgresql.enabled: false` (dùng external).
- `redis.enabled: true` (subchart riêng).
- `server.ingress.enabled: true`, host `auth.cunghoclaptrinh.online`, annotations cho cert-manager + ingress-nginx.
- `worker.replicas: 1`, `server.replicas: 1` (VPS nhỏ, scale sau).
- `resources`: requests CPU 100m/Mem 256Mi, limits 500m/512Mi cho cả server và worker.

### 3.3 Secrets (Doppler keys)

- `AUTHENTIK_SECRET_KEY` — 64-byte random
- `AUTHENTIK_POSTGRES_PASSWORD`
- `AUTHENTIK_BOOTSTRAP_PASSWORD` — admin akadmin lần đầu
- `AUTHENTIK_BOOTSTRAP_TOKEN` — API token cho automation về sau (tùy chọn)

### 3.4 Postgres bootstrap

Manual (one-shot job hoặc psql từ pod) trước khi Authentik chạy:
```sql
CREATE USER authentik WITH PASSWORD '<from doppler>';
CREATE DATABASE authentik OWNER authentik;
```

## 4. Cấu hình Authentik (post-install, manual qua UI lần đầu)

1. Login `akadmin` với bootstrap password, đổi password.
2. Tạo **Provider** OIDC:
   - Name: `goshop-oidc`
   - Client type: Confidential
   - Authorization flow: default-provider-authorization-explicit-consent (hoặc implicit)
   - Signing key: default
   - Redirect URI: `https://goshop.cunghoclaptrinh.online/api/auth/callback`
   - Scopes: `openid`, `profile`, `email`, `goshop-groups` (custom scope mapping → claim `groups`)
3. Tạo **Application** "Goshop", gắn provider trên, slug `goshop`.
4. Tạo **Groups**: `goshop-admin`, `goshop-user`. Gán user qua group.
5. Lưu `client_id` và `client_secret` vào Doppler dưới key `GOSHOP_OIDC_CLIENT_ID`, `GOSHOP_OIDC_CLIENT_SECRET`.

(Bước này có thể tự động hóa sau bằng Authentik Terraform provider hoặc blueprint YAML — out of scope cho lần đầu.)

## 5. Tích hợp goshop-api (BE)

### 5.1 Endpoints mới

- `GET /api/auth/login` — generate state + PKCE verifier, lưu vào cookie tạm (HttpOnly, short TTL), 302 tới Authentik `/application/o/authorize/`.
- `GET /api/auth/callback` — verify state, exchange code → tokens (access + id_token + refresh) tại Authentik token endpoint, verify id_token RS256 qua JWKS, JIT-provision user trong DB goshop, tạo session cookie HttpOnly Secure SameSite=Lax, redirect về `/`.
- `POST /api/auth/logout` — xóa session cookie + redirect tới Authentik end-session endpoint.
- `GET /api/auth/me` — trả thông tin user hiện tại từ session.

### 5.2 Middleware

- **Auth middleware**: đọc session cookie → tra session store (Redis hoặc DB) → attach `user` vào context. Nếu không có session, trả 401 cho các route bảo vệ.
- **RBAC middleware**: đọc `groups` claim đã lưu trong session → check group required cho route (vd: `goshop-admin` cho admin routes).

### 5.3 Session storage

Dùng Redis hiện có (namespace `data`) — key prefix `goshop:session:<sid>`, TTL = id_token exp (mặc định 1h), có refresh logic dùng refresh_token.

### 5.4 Code cần bỏ

- Toàn bộ handler `/api/auth/login` (password-based), `/api/auth/register`, password hashing logic.
- Bảng `users.password_hash` → giữ schema nhưng không dùng (cleanup sau khi migrate xong).

### 5.5 User mapping

JIT provisioning: lần đầu user OIDC login, nếu `sub` chưa có trong bảng `users` của goshop → INSERT row mới với `external_id = sub`, `email`, `name` từ claims. Lần sau lookup bằng `external_id`.

### 5.6 Config mới (env / config.yaml)

```
oidc_issuer=https://auth.cunghoclaptrinh.online/application/o/goshop/
oidc_client_id=<from secret>
oidc_client_secret=<from secret>
oidc_redirect_url=https://goshop.cunghoclaptrinh.online/api/auth/callback
oidc_post_logout_url=https://goshop.cunghoclaptrinh.online/
session_cookie_name=goshop_session
session_cookie_domain=goshop.cunghoclaptrinh.online
```

Thêm vào `goshop-secrets` ExternalSecret: `OIDC_CLIENT_ID`, `OIDC_CLIENT_SECRET`.

## 6. Tích hợp goshop-web (FE)

- Login button → `window.location = "/api/auth/login"`.
- Logout button → POST `/api/auth/logout`.
- Bỏ form login/register, bỏ logic lưu JWT trong localStorage.
- Gọi API với `credentials: 'include'` để gửi session cookie.

## 7. Rollout plan (high level)

1. **Platform**: tạo `apps/authentik/` + ExternalSecret + bootstrap Postgres DB/user. ArgoCD sync. Verify Authentik chạy + truy cập được qua `auth.cunghoclaptrinh.online`.
2. **Cấu hình Authentik**: tạo provider/application/group, lưu client credentials vào Doppler.
3. **goshop-api**: implement OIDC client trên branch riêng, test local với Authentik prod. Deploy.
4. **goshop-web**: cập nhật login button, deploy.
5. **Migrate user cũ** (nếu có): export → import manual hoặc để JIT (cần quyết định ở plan).
6. **Cleanup**: xóa code login password-based sau khi verify production ổn ≥ 1 tuần.

## 8. Non-goals / out of scope

- Social login (Google/GitHub) — có thể thêm sau qua Authentik source.
- MFA — Authentik hỗ trợ sẵn, bật sau qua flow config.
- Tự động hóa cấu hình Authentik bằng Terraform/blueprint.
- Đồng bộ user 2 chiều (Authentik ↔ goshop).

## 9. Risks & mitigations

- **Postgres dùng chung**: rủi ro blast radius. Mitigate bằng connection limit cho user `authentik`, DB riêng, theo dõi metrics.
- **Cookie session vs JWT trực tiếp**: chọn session cookie vì đơn giản, an toàn hơn (không expose token cho JS), refresh logic ở BE.
- **Authentik down = goshop login down**: chấp nhận, vì là single IdP. Session đã cấp vẫn dùng được tới khi hết TTL.
- **Migration user cũ**: nếu user đã đăng ký password-based, cần kế hoạch riêng (JIT chỉ tạo user mới khi login OIDC; user cũ phải được import vào Authentik trước).

## 10. Open questions (resolve trong writing-plans)

- User cũ migrate kiểu nào: bulk import vào Authentik, hay yêu cầu user đăng ký lại?
- Session backing store: Redis dùng chung `data` namespace hay Redis riêng của Authentik?
- Có cần custom domain cho OIDC issuer khác `auth.cunghoclaptrinh.online` không (vd: gắn behind Cloudflare)?
