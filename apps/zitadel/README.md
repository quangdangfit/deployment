# Zitadel

IdP cho Goshop B2C. Self-hosted Zitadel trên k3s.

- Domain: https://auth.cunghoclaptrinh.online
- Namespace: `auth`
- DB: external Postgres (`postgres.data.svc`), DB `zitadel`, user `zitadel`.
- Chart: `zitadel/zitadel` 9.34.1 (Zitadel app v4.13.x)

## Bootstrap (lần đầu)

1. Tạo 4 keys trong Doppler:
   - `ZITADEL_MASTERKEY` — 32 ký tự ASCII (`openssl rand -base64 24 | cut -c1-32`). **Không bao giờ đổi.**
   - `ZITADEL_DB_PASSWORD`
   - `ZITADEL_ADMIN_PASSWORD`
   - `ZITADEL_SMTP_PASSWORD` — Resend API key.
2. Tạo DB + user trên Postgres:
   ```sql
   CREATE USER zitadel WITH PASSWORD '<from doppler>';
   CREATE DATABASE zitadel OWNER zitadel;
   GRANT ALL PRIVILEGES ON DATABASE zitadel TO zitadel;
   ```
3. Apply manifest:
   ```bash
   kubectl apply -f apps/zitadel/namespace.yaml
   kubectl apply -f apps/zitadel/externalsecret.yaml
   kubectl apply -f apps/zitadel/application.yaml
   ```
4. Đợi ArgoCD sync, theo dõi:
   ```bash
   kubectl get application zitadel -n argocd -w
   kubectl logs -n auth -l app.kubernetes.io/name=zitadel --tail=200
   ```

## Login lần đầu

- URL: https://auth.cunghoclaptrinh.online
- User: `admin@cunghoclaptrinh.online`
- Password: từ Doppler `ZITADEL_ADMIN_PASSWORD`. Đổi password ngay sau login đầu.

## Cấu hình OIDC app cho Goshop

Console → project `goshop` → Applications → New:
- Type: Web
- Auth method: Code (PKCE)
- Token type: JWT
- Redirect URI: `https://goshop.cunghoclaptrinh.online/api/v1/auth/callback`
- Post-logout URI: `https://goshop.cunghoclaptrinh.online/`
- Bật "User roles inside ID Token" + "User Info inside ID Token".

Lưu `client_id` + `client_secret` vào Doppler dưới key `GOSHOP_OIDC_CLIENT_ID` / `GOSHOP_OIDC_CLIENT_SECRET` (overwrite key cũ từ Authentik).

## Login policy B2C

Settings → Login Behavior:
- Register allowed: ON
- Password reset allowed: ON
- Force email verification: ON
- Username = email: ON
- Force MFA: OFF (bật sau khi cần)

## Social login

Settings → Identity Providers → Add:
- **Google**: paste `client_id`/`secret` từ Google Cloud Console.
- **Facebook**: paste từ Meta Developer.
- Redirect URI (paste vào IdP provider): `https://auth.cunghoclaptrinh.online/ui/login/login/externalidp/callback`.
- Enable IdP trong default Login Policy.

## Branding

Settings → Branding → upload logo Goshop, primary color, font. Apply cho default instance.

## SMTP (Resend)

Settings → SMTP Settings:
- Host: `smtp.resend.com:465`
- TLS: ON
- User: `resend`
- Password: từ Doppler `ZITADEL_SMTP_PASSWORD`
- From: `noreply@<verified-domain>`
- Domain `<verified-domain>` phải verify SPF/DKIM trong Resend trước khi gửi được.

## Troubleshoot

- Pod CrashLoopBackOff: `kubectl logs -n auth -l app.kubernetes.io/name=zitadel --tail=200`.
- Migration DB fail: kiểm tra user `zitadel` có quyền `CREATE` trên DB.
- Masterkey error: đảm bảo `ZITADEL_MASTERKEY` đúng 32 ký tự ASCII.
- gRPC 502 từ ingress: kiểm tra annotation `nginx.ingress.kubernetes.io/backend-protocol: "GRPC"` đã render (chart auto-inject khi `ingress.controller: nginx`).
- Chart 9.x (Zitadel v4) tách Login UI thành component riêng (`/ui/v2/login`). Nếu login page báo 404, có thể cần enable thêm `loginUI` sub-section trong values — xem docs chart mới nhất.
