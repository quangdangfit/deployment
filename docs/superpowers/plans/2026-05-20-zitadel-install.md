# Zitadel Install & Configuration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Gỡ Authentik và cài đặt Zitadel self-hosted trên k3s (qua ArgoCD + Helm), cấu hình thành IdP B2C cho Goshop (self-service register, email verify, password reset, social login Google + Facebook, branding). Plan này chỉ phụ trách infra/deployment + Zitadel config. Tích hợp OIDC trong `goshop-api`/`goshop-web` do session khác xử lý trên repo goshop.

**Architecture:** Helm chart `zitadel/zitadel` trong namespace `auth` (dùng lại của Authentik). External Postgres ở `postgres.data.svc.cluster.local` với DB + user riêng `zitadel`. Không cần Redis. Expose qua ingress-nginx tại `auth.cunghoclaptrinh.online` với TLS letsencrypt-prod. Secrets qua Doppler ExternalSecret. ArgoCD app `apps/zitadel` tự sync.

**Tech Stack:** Helm chart `zitadel/zitadel`, ArgoCD Application, ingress-nginx (gRPC backend), cert-manager, External Secrets + Doppler, Postgres 16, Resend SMTP, k3s.

**Spec reference:** `docs/superpowers/specs/2026-05-20-zitadel-goshop-design.md`

---

## File Structure

Create:
- `apps/zitadel/application.yaml` — ArgoCD Application, multi-source (Helm + repo values).
- `apps/zitadel/namespace.yaml` — Namespace `auth` (idempotent; sẽ tồn tại sẵn nếu chưa gỡ Authentik).
- `apps/zitadel/values.yaml` — Helm values cho `zitadel/zitadel`.
- `apps/zitadel/externalsecret.yaml` — Doppler → secret `zitadel-secrets`.
- `apps/zitadel/README.md` — runbook ngắn: bootstrap DB, login lần đầu, cấu hình OIDC app + SMTP + IdP.

Delete (sau Task 14):
- `apps/authentik/` — toàn bộ thư mục.

---

## Task 1: Gỡ Authentik khỏi cluster

**Files:** (không có file thay đổi ở task này; xóa file trong Task 14)

- [ ] **Step 1: Xóa ArgoCD Application Authentik**

Run:
```bash
kubectl delete -f apps/authentik/application.yaml
```

Expected: `application.argoproj.io "authentik" deleted`. ArgoCD finalizer sẽ prune resources trong namespace `auth` (Deployment, Service, Ingress, PVC, Secret).

- [ ] **Step 2: Đợi resources cleanup**

Run:
```bash
kubectl get all,pvc,ingress -n auth
```

Expected: namespace trống (chỉ còn ExternalSecret nếu chưa xóa thủ công — Step 3 dọn nốt). Có thể đợi ~30s.

- [ ] **Step 3: Xóa ExternalSecret và secret Authentik trong namespace auth**

Run:
```bash
kubectl delete externalsecret authentik-secrets -n auth --ignore-not-found
kubectl delete secret authentik-secrets authentik-tls -n auth --ignore-not-found
```

Expected: cleanup không lỗi.

- [ ] **Step 4: Drop database authentik trong Postgres**

Run:
```bash
kubectl exec -it -n data postgres-0 -- psql -U $(kubectl get secret -n data postgres-credentials -o jsonpath='{.data.POSTGRES_USER}' | base64 -d)
```

Trong psql:
```sql
DROP DATABASE IF EXISTS authentik;
DROP USER IF EXISTS authentik;
\q
```

Expected: `DROP DATABASE` + `DROP ROLE` không lỗi.

(Không commit ở task này — chỉ thao tác cluster.)

---

## Task 2: Thêm secret keys Zitadel vào Doppler

**Files:** (Doppler UI, không có file)

- [ ] **Step 1: Tạo 4 keys mới trong Doppler config production**

Vào Doppler UI → project hiện tại → config production. Thêm:

| Key | Value |
|---|---|
| `ZITADEL_MASTERKEY` | Random 32 ký tự ASCII. Generate: `openssl rand -base64 24 \| cut -c1-32`. **Không bao giờ đổi** sau khi cài. |
| `ZITADEL_DB_PASSWORD` | Random strong password. Generate: `openssl rand -base64 24` |
| `ZITADEL_ADMIN_PASSWORD` | Random strong password (login admin lần đầu). Generate: `openssl rand -base64 18` |
| `ZITADEL_SMTP_PASSWORD` | Resend API key — lấy từ Resend dashboard (`re_xxx…`). Nếu chưa có account: đăng ký tại resend.com, verify domain, tạo API key. |

- [ ] **Step 2: Lưu giá trị nhạy cảm ra password manager**

`ZITADEL_MASTERKEY` và `ZITADEL_ADMIN_PASSWORD` lưu offline (KeePass / 1Password). Mất masterkey = mất khả năng decrypt data của Zitadel.

- [ ] **Step 3: Verify keys xuất hiện trong Doppler**

Kiểm tra dashboard. 4 keys phải có giá trị.

(Không commit.)

---

## Task 3: Bootstrap database `zitadel` trên Postgres

**Files:** (thao tác trên cluster)

- [ ] **Step 1: Lấy giá trị `ZITADEL_DB_PASSWORD` từ Doppler**

Copy giá trị, sẽ paste ở Step 3.

- [ ] **Step 2: Exec vào postgres pod**

Run:
```bash
kubectl exec -it -n data postgres-0 -- psql -U $(kubectl get secret -n data postgres-credentials -o jsonpath='{.data.POSTGRES_USER}' | base64 -d)
```

Expected: prompt `postgres=#`.

- [ ] **Step 3: Tạo user + database**

Trong psql (thay `<password>` bằng giá trị Step 1):
```sql
CREATE USER zitadel WITH PASSWORD '<password>';
CREATE DATABASE zitadel OWNER zitadel;
GRANT ALL PRIVILEGES ON DATABASE zitadel TO zitadel;
\q
```

Expected: 3 lệnh đều OK.

- [ ] **Step 4: Verify connect được bằng user mới**

Run (thay `<password>`):
```bash
kubectl exec -it -n data postgres-0 -- psql -U zitadel -d zitadel -h localhost -c "SELECT current_user, current_database();"
```

(Nhập password khi prompt.) Expected: trả về `zitadel | zitadel`.

(Không commit.)

---

## Task 4: Tạo namespace manifest

**Files:**
- Create: `apps/zitadel/namespace.yaml`

- [ ] **Step 1: Tạo file `apps/zitadel/namespace.yaml`**

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: auth
```

- [ ] **Step 2: Commit**

```bash
git add apps/zitadel/namespace.yaml
git commit -m "feat(zitadel): add namespace manifest"
```

---

## Task 5: Tạo ExternalSecret manifest

**Files:**
- Create: `apps/zitadel/externalsecret.yaml`

- [ ] **Step 1: Tạo file**

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: zitadel-secrets
  namespace: auth
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: doppler
    kind: ClusterSecretStore
  target:
    name: zitadel-secrets
    creationPolicy: Owner
  data:
    - {secretKey: ZITADEL_MASTERKEY,       remoteRef: {key: ZITADEL_MASTERKEY}}
    - {secretKey: ZITADEL_DB_PASSWORD,     remoteRef: {key: ZITADEL_DB_PASSWORD}}
    - {secretKey: ZITADEL_ADMIN_PASSWORD,  remoteRef: {key: ZITADEL_ADMIN_PASSWORD}}
    - {secretKey: ZITADEL_SMTP_PASSWORD,   remoteRef: {key: ZITADEL_SMTP_PASSWORD}}
```

- [ ] **Step 2: Apply trước khi tạo ArgoCD app (để secret có sẵn khi pod start)**

Run:
```bash
kubectl apply -f apps/zitadel/namespace.yaml
kubectl apply -f apps/zitadel/externalsecret.yaml
```

Expected: `namespace/auth unchanged` (nếu đã tồn tại) và `externalsecret.external-secrets.io/zitadel-secrets created`.

- [ ] **Step 3: Verify secret được tạo bởi External Secrets operator**

Run:
```bash
kubectl get secret zitadel-secrets -n auth -o jsonpath='{.data}' | jq 'keys'
```

Expected: array gồm 4 key: `["ZITADEL_ADMIN_PASSWORD","ZITADEL_DB_PASSWORD","ZITADEL_MASTERKEY","ZITADEL_SMTP_PASSWORD"]`. Nếu lỗi `NotFound` đợi ~30s rồi check `kubectl describe externalsecret zitadel-secrets -n auth`.

- [ ] **Step 4: Commit**

```bash
git add apps/zitadel/externalsecret.yaml
git commit -m "feat(zitadel): add ExternalSecret pulling from Doppler"
```

---

## Task 6: Tạo Helm values

**Files:**
- Create: `apps/zitadel/values.yaml`

- [ ] **Step 1: Tạo file**

```yaml
# Helm values for zitadel/zitadel
# Chart: https://charts.zitadel.com
# Reference: https://zitadel.com/docs/self-hosting/deploy/kubernetes
#
# Postgres external (cluster postgres.data.svc), không bundle DB.
# TLS terminate ở ingress (ExternalSecure=true, TLS.Enabled=false).
# Backend protocol GRPC để ingress-nginx forward h2c đúng.

replicaCount: 1

zitadel:
  masterkeySecretName: zitadel-secrets
  configmapConfig:
    ExternalDomain: auth.cunghoclaptrinh.online
    ExternalPort: 443
    ExternalSecure: true
    TLS:
      Enabled: false
    Database:
      Postgres:
        Host: postgres.data.svc.cluster.local
        Port: 5432
        Database: zitadel
        MaxOpenConns: 10
        MaxIdleConns: 5
        User:
          Username: zitadel
          SSL:
            Mode: disable
        Admin:
          Username: zitadel
          ExistingDatabase: zitadel
          SSL:
            Mode: disable
    FirstInstance:
      Org:
        Name: Goshop
        Human:
          UserName: admin
          FirstName: Admin
          LastName: Goshop
          Email:
            Address: admin@cunghoclaptrinh.online
            Verified: true
    DefaultInstance:
      SMTPConfiguration:
        SMTP:
          Host: smtp.resend.com:465
          User: resend
        From: noreply@cunghoclaptrinh.online
        FromName: Goshop
        TLS: true
        ReplyToAddress: noreply@cunghoclaptrinh.online
  dbSslRootCrtSecret: ""
  dbSslClientCrtSecret: ""

  # Map secret keys → env vars Zitadel hiểu.
  env:
    - name: ZITADEL_DATABASE_POSTGRES_USER_PASSWORD
      valueFrom:
        secretKeyRef: {name: zitadel-secrets, key: ZITADEL_DB_PASSWORD}
    - name: ZITADEL_DATABASE_POSTGRES_ADMIN_PASSWORD
      valueFrom:
        secretKeyRef: {name: zitadel-secrets, key: ZITADEL_DB_PASSWORD}
    - name: ZITADEL_FIRSTINSTANCE_ORG_HUMAN_PASSWORD
      valueFrom:
        secretKeyRef: {name: zitadel-secrets, key: ZITADEL_ADMIN_PASSWORD}
    - name: ZITADEL_DEFAULTINSTANCE_SMTPCONFIGURATION_SMTP_PASSWORD
      valueFrom:
        secretKeyRef: {name: zitadel-secrets, key: ZITADEL_SMTP_PASSWORD}

ingress:
  enabled: true
  className: nginx
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
    nginx.ingress.kubernetes.io/backend-protocol: "GRPC"
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
  hosts:
    - host: auth.cunghoclaptrinh.online
      paths:
        - path: /
          pathType: Prefix
  tls:
    - hosts: [auth.cunghoclaptrinh.online]
      secretName: zitadel-tls

resources:
  requests: {cpu: 100m, memory: 256Mi}
  limits:   {cpu: 500m, memory: 512Mi}
```

> Lưu ý: nếu sau khi apply Zitadel báo `masterkey: file does not exist` hoặc không nhận env, fallback là mount secret thành file rồi set `ZITADEL_MASTERKEY` qua env trực tiếp; xem README task 8 phần troubleshoot.

- [ ] **Step 2: Commit**

```bash
git add apps/zitadel/values.yaml
git commit -m "feat(zitadel): add Helm values"
```

---

## Task 7: Tạo ArgoCD Application

**Files:**
- Create: `apps/zitadel/application.yaml`

- [ ] **Step 1: Tạo file**

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: zitadel
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  sources:
    - repoURL: https://charts.zitadel.com
      chart: zitadel
      targetRevision: 8.6.1
      helm:
        releaseName: zitadel
        valueFiles:
          - $values/apps/zitadel/values.yaml
    - repoURL: https://github.com/quangdangfit/deployment
      targetRevision: main
      ref: values
  destination:
    server: https://kubernetes.default.svc
    namespace: auth
  syncPolicy:
    automated: {prune: true, selfHeal: true}
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true
  ignoreDifferences:
    - group: external-secrets.io
      kind: ExternalSecret
      jqPathExpressions:
        - .spec.data[].remoteRef.conversionStrategy
        - .spec.data[].remoteRef.decodingStrategy
        - .spec.data[].remoteRef.metadataPolicy
        - .spec.data[].remoteRef.nullBytePolicy
      jsonPointers: [/spec/target/deletionPolicy]
```

> Verify `targetRevision: 8.6.1` còn là latest stable chart version trước khi commit: `helm search repo zitadel/zitadel --versions | head` (cần `helm repo add zitadel https://charts.zitadel.com && helm repo update` trước). Nếu khác, đổi số trong file.

- [ ] **Step 2: Apply Application vào cluster**

Run:
```bash
kubectl apply -f apps/zitadel/application.yaml
```

Expected: `application.argoproj.io/zitadel created`.

- [ ] **Step 3: Theo dõi sync ArgoCD**

Run:
```bash
kubectl get application zitadel -n argocd -w
```

Expected: Sync `Synced`, Health `Progressing` → `Healthy` sau ~2-3 phút (lần đầu Zitadel chạy migration DB).

Nếu Health `Degraded`:
```bash
kubectl describe application zitadel -n argocd
kubectl logs -n auth -l app.kubernetes.io/name=zitadel --tail=200
```

Common issues:
- Postgres connect fail → check password Doppler khớp với Task 3.
- Masterkey length != 32 → re-roll trong Doppler, kill pod để pick up.
- Ingress TLS chưa cấp → đợi cert-manager (`kubectl describe certificate zitadel-tls -n auth`).

- [ ] **Step 4: Verify endpoint**

Run:
```bash
curl -sS https://auth.cunghoclaptrinh.online/.well-known/openid-configuration | jq '.issuer, .jwks_uri'
```

Expected:
```
"https://auth.cunghoclaptrinh.online"
"https://auth.cunghoclaptrinh.online/oauth/v2/keys"
```

- [ ] **Step 5: Commit**

```bash
git add apps/zitadel/application.yaml
git commit -m "feat(zitadel): add ArgoCD Application"
```

---

## Task 8: Viết README runbook

**Files:**
- Create: `apps/zitadel/README.md`

- [ ] **Step 1: Tạo file**

```markdown
# Zitadel

IdP cho Goshop B2C. Self-hosted Zitadel trên k3s.

- Domain: https://auth.cunghoclaptrinh.online
- Namespace: `auth`
- DB: external Postgres (`postgres.data.svc`), DB `zitadel`, user `zitadel`.

## Bootstrap (lần đầu)

1. Tạo 4 keys trong Doppler: `ZITADEL_MASTERKEY` (32 chars), `ZITADEL_DB_PASSWORD`, `ZITADEL_ADMIN_PASSWORD`, `ZITADEL_SMTP_PASSWORD` (Resend API key).
2. Tạo DB + user trên Postgres:
   ```sql
   CREATE USER zitadel WITH PASSWORD '<from doppler>';
   CREATE DATABASE zitadel OWNER zitadel;
   GRANT ALL PRIVILEGES ON DATABASE zitadel TO zitadel;
   ```
3. `kubectl apply -f apps/zitadel/namespace.yaml -f apps/zitadel/externalsecret.yaml`
4. `kubectl apply -f apps/zitadel/application.yaml` — ArgoCD tự sync.

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
- Register allowed: on
- Password reset allowed: on
- Force email verification: on
- Username = email

## Social login

Settings → Identity Providers → Add:
- Google: paste `client_id`/`secret` từ Google Cloud Console.
- Facebook: paste từ Meta Developer.
- Redirect URI (paste vào IdP provider): `https://auth.cunghoclaptrinh.online/ui/login/login/externalidp/callback`.
- Enable IdP trong default Login Policy.

## Branding

Settings → Branding → upload logo Goshop, primary color, font. Apply cho default instance.

## SMTP (Resend)

Settings → SMTP Settings:
- Host: `smtp.resend.com:465`
- TLS: on
- User: `resend`
- Password: Doppler `ZITADEL_SMTP_PASSWORD`
- From: `noreply@<verified-domain>`
- Test: send mail → kiểm tra inbox.

## Troubleshoot

- Pod CrashLoopBackOff → `kubectl logs -n auth -l app.kubernetes.io/name=zitadel --tail=200`.
- Migration DB fail → check user `zitadel` có quyền `CREATE` trên DB không.
- Masterkey error → đảm bảo `ZITADEL_MASTERKEY` đúng 32 ký tự ASCII.
- gRPC 502 từ ingress → kiểm tra annotation `nginx.ingress.kubernetes.io/backend-protocol: "GRPC"` đã apply.
```

- [ ] **Step 2: Commit**

```bash
git add apps/zitadel/README.md
git commit -m "docs(zitadel): add bootstrap and runbook README"
```

---

## Task 9: Login admin lần đầu và đổi password

**Files:** (Console UI, không có file)

- [ ] **Step 1: Mở browser tới `https://auth.cunghoclaptrinh.online`**

Expected: trang login Zitadel.

- [ ] **Step 2: Login bằng `admin@cunghoclaptrinh.online` + `ZITADEL_ADMIN_PASSWORD`**

Nếu Zitadel yêu cầu đổi password lần đầu → đổi sang password mới mạnh, lưu password manager.

- [ ] **Step 3: Verify vào được Console (UI Zitadel)**

Expected: thấy default org `Goshop`, sidebar có "Projects", "Users", "Settings".

---

## Task 10: Tạo Project + OIDC Application cho Goshop

**Files:** (Console UI)

- [ ] **Step 1: Tạo Project `goshop`**

Console → Projects → New Project → Name: `goshop` → Create.

- [ ] **Step 2: Tạo Application OIDC trong project**

Vào project `goshop` → Applications → New:
- Name: `goshop-web`
- Type: **Web**
- Authentication method: **CODE** (Authorization Code + PKCE)
- Redirect URIs: `https://goshop.cunghoclaptrinh.online/api/v1/auth/callback`
- Post Logout URIs: `https://goshop.cunghoclaptrinh.online/`
- Tạo xong → tab Token Settings:
  - Auth Token Type: **JWT**
  - User roles inside ID Token: ON
  - User Info inside ID Token: ON
  - Access Token Role Assertion: ON
- Save.

- [ ] **Step 3: Copy Client ID + Client Secret**

Trong tab "OIDC Configuration" hiển thị `clientID` + `clientSecret`. Copy cả 2.

- [ ] **Step 4: Lưu vào Doppler**

Vào Doppler → config production → set 2 keys (overwrite nếu đã tồn tại từ Authentik):
- `GOSHOP_OIDC_CLIENT_ID` = giá trị clientID
- `GOSHOP_OIDC_CLIENT_SECRET` = giá trị clientSecret

- [ ] **Step 5: Tạo Project Roles `admin` và `user`**

Trong project `goshop` → Roles → New: tạo 2 role với key `admin` và `user` (display name tùy).

---

## Task 11: Cấu hình Login Policy B2C

**Files:** (Console UI)

- [ ] **Step 1: Mở Default Login Behavior settings**

Console → Settings (icon ⚙ góc phải) → Login Behavior and Security.

- [ ] **Step 2: Bật các flag B2C**

- Username Password allowed: ON
- Register allowed: ON
- Password reset allowed: ON
- Force MFA: OFF (lần đầu; có thể bật sau)
- Username = email: ON (chỉnh ở Login Texts / Username Format nếu có)

- [ ] **Step 3: Save**

Expected: thấy banner "Settings updated".

---

## Task 12: Cấu hình Google IdP

**Files:** (Google Cloud + Console UI)

- [ ] **Step 1: Tạo OAuth client tại Google Cloud Console**

console.cloud.google.com → APIs & Services → Credentials → Create Credentials → OAuth client ID:
- Application type: Web application
- Authorized redirect URIs: `https://auth.cunghoclaptrinh.online/ui/login/login/externalidp/callback`
- Lưu lại `Client ID` + `Client Secret`.

- [ ] **Step 2: Thêm IdP vào Zitadel**

Console → Settings → Identity Providers → New → Google:
- Name: `Google`
- Client ID + Client Secret: paste từ Step 1.
- Scopes: `openid profile email`
- Auto Register: ON (JIT tạo user khi login lần đầu)
- Save.

- [ ] **Step 3: Enable IdP trong Default Login Policy**

Settings → Login Behavior → Identity Providers → enable Google.

- [ ] **Step 4: Test**

Mở incognito → `https://auth.cunghoclaptrinh.online/ui/login` → bấm nút Google → đăng nhập Google account test → xác nhận redirect về Zitadel Console với user mới được tạo.

---

## Task 13: Cấu hình Facebook IdP

**Files:** (Meta Developer + Console UI)

- [ ] **Step 1: Tạo App tại Meta Developer**

developers.facebook.com → My Apps → Create App → Type "Consumer" → Add Product "Facebook Login":
- Valid OAuth Redirect URIs: `https://auth.cunghoclaptrinh.online/ui/login/login/externalidp/callback`
- Settings → Basic: lấy `App ID` + `App Secret`.
- Chuyển App sang Live mode (cần điền Privacy Policy URL).

- [ ] **Step 2: Thêm IdP vào Zitadel**

Console → Settings → Identity Providers → New → Facebook (hoặc Generic OAuth nếu Facebook không có sẵn):
- Client ID = App ID; Client Secret = App Secret.
- Scopes: `email public_profile`
- Auto Register: ON
- Save.

- [ ] **Step 3: Enable trong Default Login Policy**

Settings → Login Behavior → Identity Providers → enable Facebook.

- [ ] **Step 4: Test**

Incognito → trang login Zitadel → bấm Facebook → login → verify redirect và user mới.

---

## Task 14: Branding

**Files:** (Console UI; logo file local trên máy)

- [ ] **Step 1: Chuẩn bị assets**

Logo PNG (light + dark mode nếu có), icon, favicon. Kích thước theo gợi ý Zitadel (logo ≤ 200KB).

- [ ] **Step 2: Apply branding**

Console → Settings → Branding (Private Labeling):
- Upload logo + icon.
- Primary color: hex màu chính của Goshop.
- Background color, font color tùy chỉnh.
- Apply to default instance: ON.

- [ ] **Step 3: Verify**

Mở incognito → trang login → xác nhận thấy logo + màu đúng.

---

## Task 15: SMTP test với Resend

**Files:** (Console UI)

- [ ] **Step 1: Verify SMTP đã được seed từ Helm values**

Console → Settings → SMTP Settings → kiểm tra host `smtp.resend.com:465`, user `resend`, From `noreply@<domain>`. Password đã được mount từ secret.

Nếu chưa có (Helm seed không hoạt động): điền tay rồi save.

- [ ] **Step 2: Verify Resend domain**

Tại resend.com dashboard → Domains → ensure domain trong `From` đã verified (SPF + DKIM records đã add vào DNS). Nếu chưa: thêm DNS records theo hướng dẫn Resend và đợi verify.

- [ ] **Step 3: Send test email**

Console SMTP settings → nút **Test Email** → nhập email cá nhân → send.

Expected: nhận được mail trong vòng 1-2 phút. Check spam folder nếu không thấy.

- [ ] **Step 4: Test luồng register thật**

Incognito → trang login → Register → đăng ký với email cá nhân → kiểm tra inbox có mail verify → click link verify → xác nhận user status `Active` trong Console.

- [ ] **Step 5: Test luồng reset password**

Trang login → "Forgot password?" → nhập email vừa tạo → kiểm tra inbox có mail reset → click link → đặt password mới → login lại.

---

## Task 16: Bàn giao credentials cho session goshop

**Files:** (không có file repo này)

- [ ] **Step 1: Verify Doppler đã có key mới**

Doppler dashboard → config production → confirm 2 keys có giá trị mới:
- `GOSHOP_OIDC_CLIENT_ID`
- `GOSHOP_OIDC_CLIENT_SECRET`

- [ ] **Step 2: Soạn handover note cho session goshop**

Thông tin cần bàn giao (paste vào chat của session khác hoặc lưu vào ghi chú):

```
Zitadel đã sẵn sàng. Bàn giao tích hợp:

- Issuer:    https://auth.cunghoclaptrinh.online
- Discovery: https://auth.cunghoclaptrinh.online/.well-known/openid-configuration
- JWKS:      https://auth.cunghoclaptrinh.online/oauth/v2/keys
- Scopes:    openid profile email offline_access urn:zitadel:iam:org:project:roles
- Client credentials đã trong Doppler: GOSHOP_OIDC_CLIENT_ID / GOSHOP_OIDC_CLIENT_SECRET
- Roles claim: urn:zitadel:iam:org:project:roles (map { "<role>": { "<orgId>": "<orgDomain>" } })
- Redirect URI đã đăng ký: https://goshop.cunghoclaptrinh.online/api/v1/auth/callback
- Post-logout URI: https://goshop.cunghoclaptrinh.online/
```

---

## Task 17: Cleanup Authentik (sau khi Goshop chạy ổn ≥ 1 tuần)

**Files:**
- Delete: `apps/authentik/` (toàn bộ thư mục)

- [ ] **Step 1: Confirm Goshop production đã chạy ổn ≥ 1 tuần với Zitadel**

Không có user complaint, login/register/social/reset đều OK. Đã sang ngày đủ 7 ngày sau khi Goshop deploy production.

- [ ] **Step 2: Xóa Doppler keys cũ**

Doppler → config production → xóa 4 keys:
- `AUTHENTIK_SECRET_KEY`
- `AUTHENTIK_POSTGRES_PASSWORD`
- `AUTHENTIK_BOOTSTRAP_PASSWORD`
- `AUTHENTIK_BOOTSTRAP_TOKEN`

- [ ] **Step 3: Xóa thư mục `apps/authentik/`**

Run:
```bash
git rm -r apps/authentik/
```

Expected: 5 file bị xóa (application.yaml, namespace.yaml, values.yaml, externalsecret.yaml, README.md).

- [ ] **Step 4: Xóa spec + plan Authentik cũ (tùy chọn — giữ làm tham khảo cũng OK)**

Nếu muốn giữ lịch sử, skip. Nếu muốn clean:
```bash
git rm docs/superpowers/specs/2026-05-19-authentik-goshop-design.md docs/superpowers/plans/2026-05-19-authentik-install.md
```

- [ ] **Step 5: Commit**

```bash
git commit -m "chore(authentik): remove Authentik after Zitadel migration

Zitadel đã chạy ổn định ≥ 1 tuần. Gỡ toàn bộ artifact Authentik
khỏi repo."
```

---

## Done criteria

- [ ] `https://auth.cunghoclaptrinh.online` truy cập được, hiển thị branding Goshop.
- [ ] Login admin OK.
- [ ] Project `goshop` + OIDC app `goshop-web` đã tạo, credentials lưu Doppler.
- [ ] Register self-service + email verify chạy được (test luồng end-to-end ở Task 15).
- [ ] Forgot password chạy được.
- [ ] Login Google + Facebook chạy được.
- [ ] Session goshop khác đã pick up credentials và tích hợp xong (out-of-band confirm).
- [ ] Authentik đã được gỡ (Task 17 hoàn tất).
