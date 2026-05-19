# Authentik Install & Configuration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Cài đặt Authentik trên k3s cluster (qua ArgoCD + Helm) và cấu hình OIDC provider cho Goshop. Plan này chỉ phụ trách phần infra/deployment + Authentik config. Phần tích hợp OIDC code trong `goshop-api` và `goshop-web` thuộc plan riêng (sẽ viết trong repo goshop sau khi Phase 1 này done).

**Architecture:** Authentik Helm chart `goauthentik/authentik` triển khai trong namespace `auth`, dùng external Postgres (cluster `postgres.data.svc`) với DB riêng, Redis subchart đi kèm. Expose qua ingress-nginx tại `auth.cunghoclaptrinh.online` với TLS letsencrypt-prod. Secrets qua Doppler ExternalSecret. ArgoCD app mới (`apps/authentik`) tự sync.

**Tech Stack:** Helm chart `goauthentik/authentik`, ArgoCD Application, ingress-nginx, cert-manager, External Secrets + Doppler, Postgres 16, k3s.

**Spec reference:** `docs/superpowers/specs/2026-05-19-authentik-goshop-design.md`

---

## File Structure

Create:
- `apps/authentik/application.yaml` — ArgoCD Application bám pattern goshop-api, dùng repo Helm trực tiếp (không qua `charts/webapp`).
- `apps/authentik/namespace.yaml` — Namespace `auth`.
- `apps/authentik/values.yaml` — Helm values cho `goauthentik/authentik`.
- `apps/authentik/externalsecret.yaml` — Doppler → secret `authentik-secrets` trong namespace `auth`.
- `apps/authentik/README.md` — runbook ngắn: bootstrap DB, login lần đầu, tạo OIDC provider.

Modify: (none ở Phase 1; goshop-secrets sẽ update khi Phase 2 — tích hợp BE).

---

## Task 1: Thêm các secret keys Authentik vào Doppler

**Files:** (Doppler UI, không có file)

- [ ] **Step 1: Tạo 4 keys trong Doppler project hiện tại**

Vào Doppler UI → project hiện tại → config production. Thêm:

| Key | Value |
|---|---|
| `AUTHENTIK_SECRET_KEY` | Random 64 bytes hex. Generate: `openssl rand -hex 32` |
| `AUTHENTIK_POSTGRES_PASSWORD` | Random strong password. Generate: `openssl rand -base64 24` |
| `AUTHENTIK_BOOTSTRAP_PASSWORD` | Random strong password (để login `akadmin` lần đầu). Generate: `openssl rand -base64 18` |
| `AUTHENTIK_BOOTSTRAP_TOKEN` | Random hex 32 bytes (token API cho automation sau). Generate: `openssl rand -hex 32` |

Lưu lại `AUTHENTIK_BOOTSTRAP_PASSWORD` ra password manager — sẽ cần để login `akadmin` lần đầu.

- [ ] **Step 2: Verify keys xuất hiện trong Doppler**

Kiểm tra trong Doppler dashboard, đảm bảo 4 keys trên đã có giá trị.

(Không có commit ở task này — chỉ ngoài repo.)

---

## Task 2: Tạo database và user `authentik` trên Postgres cluster

**Files:** (không có file mới — thao tác trực tiếp trên cluster)

- [ ] **Step 1: Lấy giá trị `AUTHENTIK_POSTGRES_PASSWORD` từ Doppler**

Copy giá trị key `AUTHENTIK_POSTGRES_PASSWORD` từ Doppler (cần để tạo user).

- [ ] **Step 2: Exec vào postgres pod**

Run:
```bash
kubectl exec -it -n data postgres-0 -- psql -U $(kubectl get secret -n data postgres-credentials -o jsonpath='{.data.POSTGRES_USER}' | base64 -d)
```

Expected: vào được psql prompt `postgres=#`.

- [ ] **Step 3: Tạo user và database**

Trong psql, chạy (thay `<password>` bằng giá trị từ Step 1, giữ nguyên dấu nháy đơn):
```sql
CREATE USER authentik WITH PASSWORD '<password>';
CREATE DATABASE authentik OWNER authentik;
GRANT ALL PRIVILEGES ON DATABASE authentik TO authentik;
\q
```

Expected: 3 lệnh đều `CREATE ROLE` / `CREATE DATABASE` / `GRANT` không lỗi.

- [ ] **Step 4: Verify connection**

Run:
```bash
kubectl exec -it -n data postgres-0 -- psql -U authentik -d authentik -c "SELECT current_user, current_database();"
```
(Khi prompt password, nhập password vừa tạo.)

Expected: trả về `authentik | authentik`.

---

## Task 3: Tạo namespace `auth`

**Files:**
- Create: `apps/authentik/namespace.yaml`

- [ ] **Step 1: Tạo file namespace**

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: auth
```

- [ ] **Step 2: Commit**

```bash
git add apps/authentik/namespace.yaml
git commit -m "feat(authentik): add auth namespace manifest"
```

---

## Task 4: Tạo ExternalSecret cho Authentik

**Files:**
- Create: `apps/authentik/externalsecret.yaml`

- [ ] **Step 1: Viết file ExternalSecret**

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: authentik-secrets
  namespace: auth
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: doppler
    kind: ClusterSecretStore
  target:
    name: authentik-secrets
    creationPolicy: Owner
  data:
    - {secretKey: AUTHENTIK_SECRET_KEY,         remoteRef: {key: AUTHENTIK_SECRET_KEY}}
    - {secretKey: AUTHENTIK_POSTGRES_PASSWORD,  remoteRef: {key: AUTHENTIK_POSTGRES_PASSWORD}}
    - {secretKey: AUTHENTIK_BOOTSTRAP_PASSWORD, remoteRef: {key: AUTHENTIK_BOOTSTRAP_PASSWORD}}
    - {secretKey: AUTHENTIK_BOOTSTRAP_TOKEN,    remoteRef: {key: AUTHENTIK_BOOTSTRAP_TOKEN}}
```

- [ ] **Step 2: Apply namespace + ExternalSecret tay (để verify trước khi ArgoCD nắm)**

Run:
```bash
kubectl apply -f apps/authentik/namespace.yaml
kubectl apply -f apps/authentik/externalsecret.yaml
```

Expected: namespace created, externalsecret created.

- [ ] **Step 3: Verify secret được sync từ Doppler**

Wait ~30s sau đó:
```bash
kubectl get externalsecret -n auth authentik-secrets
kubectl get secret -n auth authentik-secrets -o jsonpath='{.data}' | jq 'keys'
```

Expected: `STATUS` của externalsecret là `SecretSynced`. Secret có 4 keys: `AUTHENTIK_SECRET_KEY`, `AUTHENTIK_POSTGRES_PASSWORD`, `AUTHENTIK_BOOTSTRAP_PASSWORD`, `AUTHENTIK_BOOTSTRAP_TOKEN`.

- [ ] **Step 4: Commit**

```bash
git add apps/authentik/externalsecret.yaml
git commit -m "feat(authentik): add externalsecret pulling Authentik creds from Doppler"
```

---

## Task 5: Tạo Helm values cho Authentik

**Files:**
- Create: `apps/authentik/values.yaml`

- [ ] **Step 1: Viết values.yaml**

```yaml
# Helm values for goauthentik/authentik
# Chart: https://charts.goauthentik.io
# Values reference: https://github.com/goauthentik/authentik/blob/main/website/docs/install-config/install/kubernetes.md

global:
  # Đọc env từ secret authentik-secrets (do ExternalSecret sync từ Doppler)
  envFrom:
    - secretRef:
        name: authentik-secrets

authentik:
  # secret_key: được set từ env AUTHENTIK_SECRET_KEY (envFrom phía trên)
  error_reporting:
    enabled: false
  postgresql:
    host: postgres.data.svc.cluster.local
    port: 5432
    name: authentik
    user: authentik
    # password: AUTHENTIK_POSTGRES_PASSWORD đến từ envFrom; Authentik đọc env AUTHENTIK_POSTGRESQL__PASSWORD
    # → cần map qua bootstrap_secret hoặc env explicit. Xem env block bên dưới.
  redis:
    host: authentik-redis-master
    password: ""

# Map env cho Authentik đọc password Postgres từ secret
env:
  AUTHENTIK_POSTGRESQL__PASSWORD:
    valueFrom:
      secretKeyRef:
        name: authentik-secrets
        key: AUTHENTIK_POSTGRES_PASSWORD
  AUTHENTIK_SECRET_KEY:
    valueFrom:
      secretKeyRef:
        name: authentik-secrets
        key: AUTHENTIK_SECRET_KEY
  AUTHENTIK_BOOTSTRAP_PASSWORD:
    valueFrom:
      secretKeyRef:
        name: authentik-secrets
        key: AUTHENTIK_BOOTSTRAP_PASSWORD
  AUTHENTIK_BOOTSTRAP_TOKEN:
    valueFrom:
      secretKeyRef:
        name: authentik-secrets
        key: AUTHENTIK_BOOTSTRAP_TOKEN

server:
  replicas: 1
  resources:
    requests: {cpu: 100m, memory: 384Mi}
    limits:   {cpu: 600m, memory: 768Mi}
  ingress:
    enabled: true
    ingressClassName: nginx
    annotations:
      cert-manager.io/cluster-issuer: letsencrypt-prod
    hosts:
      - host: auth.cunghoclaptrinh.online
        paths:
          - path: /
            pathType: Prefix
    tls:
      - hosts: [auth.cunghoclaptrinh.online]
        secretName: authentik-tls

worker:
  replicas: 1
  resources:
    requests: {cpu: 100m, memory: 256Mi}
    limits:   {cpu: 500m, memory: 512Mi}

# Subchart Redis của Bitnami đi kèm Authentik chart
redis:
  enabled: true
  architecture: standalone
  auth:
    enabled: false
  master:
    persistence:
      enabled: true
      size: 1Gi
    resources:
      requests: {cpu: 50m, memory: 64Mi}
      limits:   {cpu: 200m, memory: 256Mi}

# Tắt postgres subchart vì dùng external
postgresql:
  enabled: false
```

- [ ] **Step 2: Commit**

```bash
git add apps/authentik/values.yaml
git commit -m "feat(authentik): add Helm values for Authentik server+worker+redis"
```

---

## Task 6: Tạo ArgoCD Application cho Authentik

**Files:**
- Create: `apps/authentik/application.yaml`

- [ ] **Step 1: Viết Application manifest**

Lưu ý: khác với goshop-api dùng `charts/webapp` local, Authentik dùng Helm chart upstream → cấu hình 2 sources: 1 cho chart upstream, 1 cho values trong repo.

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: authentik
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  sources:
    - repoURL: https://charts.goauthentik.io
      chart: authentik
      targetRevision: 2025.10.0   # NOTE: bump theo release mới nhất tại thời điểm apply
      helm:
        releaseName: authentik
        valueFiles:
          - $values/apps/authentik/values.yaml
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

- [ ] **Step 2: Verify chart version còn tồn tại**

Run:
```bash
helm repo add authentik https://charts.goauthentik.io 2>/dev/null || true
helm repo update authentik
helm search repo authentik/authentik --versions | head -5
```

Expected: thấy version `2025.10.0` (hoặc cập nhật `targetRevision` thành version mới nhất hiển thị nếu version trên không còn). Lưu lại version đã chọn.

- [ ] **Step 3: Commit**

```bash
git add apps/authentik/application.yaml
git commit -m "feat(authentik): add ArgoCD Application for Authentik chart"
```

- [ ] **Step 4: Push lên main để ArgoCD có thể đọc**

```bash
git push origin main
```

Expected: push thành công.

---

## Task 7: Apply ArgoCD Application và verify Authentik chạy

**Files:** (không có file mới)

- [ ] **Step 1: Apply Application vào ArgoCD**

Run:
```bash
kubectl apply -f apps/authentik/application.yaml
```

Expected: `application.argoproj.io/authentik created`.

- [ ] **Step 2: Watch sync status**

Run:
```bash
kubectl get application -n argocd authentik -w
```

Đợi tới khi `SYNC STATUS = Synced` và `HEALTH STATUS = Healthy`. Có thể mất 3-5 phút (pull image authentik server + worker + redis init + chạy migrations).

Ctrl+C khi đã Healthy.

- [ ] **Step 3: Verify pods**

Run:
```bash
kubectl get pods -n auth
```

Expected: ít nhất 3 pods running:
- `authentik-server-...` (Running, READY 1/1)
- `authentik-worker-...` (Running, READY 1/1)
- `authentik-redis-master-0` (Running, READY 1/1)

- [ ] **Step 4: Verify migrations chạy xong**

Run:
```bash
kubectl logs -n auth deploy/authentik-server | grep -i "migrations\|listening\|startup" | tail -20
```

Expected: thấy log `Applied migrations` và `Listening on 0.0.0.0:9000` (hoặc tương đương).

- [ ] **Step 5: Verify ingress + TLS**

Run:
```bash
kubectl get ingress -n auth
kubectl get certificate -n auth
```

Expected: ingress có host `auth.cunghoclaptrinh.online`, certificate `authentik-tls` có `READY=True` (chờ vài phút nếu chưa).

- [ ] **Step 6: Verify DNS đã point về cluster**

Trước khi mở browser, đảm bảo `auth.cunghoclaptrinh.online` đã có A record trỏ về IP cluster ingress.

Run:
```bash
dig +short auth.cunghoclaptrinh.online
dig +short goshop.cunghoclaptrinh.online
```

Expected: cả 2 trả về cùng IP. Nếu chưa, vào DNS provider và thêm A record `auth` → IP của `goshop.cunghoclaptrinh.online`.

- [ ] **Step 7: Truy cập Authentik UI**

Mở browser: https://auth.cunghoclaptrinh.online

Expected: trang login Authentik hiển thị, TLS valid (không cảnh báo).

---

## Task 8: Bootstrap admin user

**Files:** (không có file)

- [ ] **Step 1: Login với `akadmin`**

Tại trang login, nhập:
- Username: `akadmin`
- Password: giá trị `AUTHENTIK_BOOTSTRAP_PASSWORD` từ Doppler

Expected: vào được admin dashboard.

- [ ] **Step 2: Đổi password và setup email**

Vào: `Directory → Users → akadmin → Set password`. Đổi sang password mới, lưu vào password manager.

Email: set `akadmin@cunghoclaptrinh.online` (hoặc email thật của bạn).

(Bootstrap password trong Doppler vẫn giữ vì lần đầu chạy; nhưng từ giờ login bằng password mới.)

---

## Task 9: Tạo OIDC Provider cho Goshop

**Files:** (không có file — cấu hình qua Authentik UI)

- [ ] **Step 1: Tạo Signing Key (nếu chưa có)**

Vào `System → Certificates`. Verify đã có `authentik Self-signed Certificate` (default). Nếu chưa, tạo mới với CN bất kỳ.

- [ ] **Step 2: Tạo Scope Mapping cho group claim**

Vào `Customization → Property Mappings → Create → Scope Mapping`:
- Name: `goshop-groups`
- Scope name: `groups`
- Description: `Groups claim for goshop RBAC`
- Expression:
  ```python
  return {
      "groups": [group.name for group in user.ak_groups.all()],
  }
  ```

Save.

- [ ] **Step 3: Tạo Provider OIDC**

Vào `Applications → Providers → Create → OAuth2/OpenID Provider`:
- Name: `goshop-oidc`
- Authentication flow: `default-authentication-flow`
- Authorization flow: `default-provider-authorization-explicit-consent` (hoặc implicit nếu muốn skip consent screen)
- Protocol settings:
  - Client type: `Confidential`
  - Client ID: để Authentik auto-generate, copy lại sau
  - Client Secret: auto-generate, copy lại sau
  - Redirect URIs (strict mode): `https://goshop.cunghoclaptrinh.online/api/auth/callback`
  - Signing key: chọn cert ở Step 1
- Advanced protocol settings → Scopes: chọn `openid`, `email`, `profile`, và `goshop-groups` (scope mapping vừa tạo)
- Subject mode: `Based on the User's hashed ID` (hoặc `username` — tùy preference; UUID an toàn hơn)

Save. Click vào provider vừa tạo, copy lại **Client ID** và **Client Secret**.

- [ ] **Step 4: Tạo Application**

Vào `Applications → Applications → Create`:
- Name: `Goshop`
- Slug: `goshop`
- Provider: chọn `goshop-oidc`
- Launch URL: `https://goshop.cunghoclaptrinh.online/`
- UI settings: tùy chọn icon/description.

Save.

- [ ] **Step 5: Tạo Groups cho RBAC**

Vào `Directory → Groups → Create`:
- Group 1: name `goshop-admin`
- Group 2: name `goshop-user`

- [ ] **Step 6: Verify OIDC discovery endpoint**

Run:
```bash
curl -s https://auth.cunghoclaptrinh.online/application/o/goshop/.well-known/openid-configuration | jq '.issuer, .authorization_endpoint, .token_endpoint, .jwks_uri'
```

Expected:
```
"https://auth.cunghoclaptrinh.online/application/o/goshop/"
"https://auth.cunghoclaptrinh.online/application/o/authorize/"
"https://auth.cunghoclaptrinh.online/application/o/token/"
"https://auth.cunghoclaptrinh.online/application/o/goshop/jwks/"
```

- [ ] **Step 7: Lưu client credentials vào Doppler**

Vào Doppler, thêm 2 keys mới:
- `GOSHOP_OIDC_CLIENT_ID` = Client ID từ Step 3
- `GOSHOP_OIDC_CLIENT_SECRET` = Client Secret từ Step 3
- `GOSHOP_OIDC_ISSUER` = `https://auth.cunghoclaptrinh.online/application/o/goshop/`

Đây là tiền đề cho Phase 2 (BE tích hợp).

---

## Task 10: Viết runbook README

**Files:**
- Create: `apps/authentik/README.md`

- [ ] **Step 1: Viết README**

```markdown
# Authentik

Single sign-on / OIDC provider cho Goshop.

- URL: https://auth.cunghoclaptrinh.online
- Namespace: `auth`
- Chart: `goauthentik/authentik` (xem `application.yaml` để biết version)
- Data store: external Postgres (`postgres.data.svc.cluster.local`, DB `authentik`), Redis subchart riêng trong namespace.

## Secrets (Doppler)

- `AUTHENTIK_SECRET_KEY` — Django secret key, 64 hex chars.
- `AUTHENTIK_POSTGRES_PASSWORD` — password user DB `authentik`.
- `AUTHENTIK_BOOTSTRAP_PASSWORD` — password admin `akadmin` lần đầu.
- `AUTHENTIK_BOOTSTRAP_TOKEN` — API token cho automation.
- `GOSHOP_OIDC_CLIENT_ID` / `GOSHOP_OIDC_CLIENT_SECRET` / `GOSHOP_OIDC_ISSUER` — dùng bởi goshop-api.

## Bootstrap Postgres DB

Chạy 1 lần khi cài mới:

\`\`\`bash
kubectl exec -it -n data postgres-0 -- psql -U postgres
\`\`\`

\`\`\`sql
CREATE USER authentik WITH PASSWORD '<từ Doppler AUTHENTIK_POSTGRES_PASSWORD>';
CREATE DATABASE authentik OWNER authentik;
GRANT ALL PRIVILEGES ON DATABASE authentik TO authentik;
\`\`\`

## OIDC integration cho Goshop

- Provider name: `goshop-oidc`
- Application slug: `goshop`
- Redirect URI: `https://goshop.cunghoclaptrinh.online/api/auth/callback`
- Scopes: `openid`, `profile`, `email`, `goshop-groups`
- Groups: `goshop-admin`, `goshop-user`

OIDC discovery: https://auth.cunghoclaptrinh.online/application/o/goshop/.well-known/openid-configuration

## Operations

\`\`\`bash
# Logs
kubectl logs -n auth deploy/authentik-server -f
kubectl logs -n auth deploy/authentik-worker -f

# Restart sau khi đổi values
kubectl rollout restart -n auth deploy/authentik-server deploy/authentik-worker

# Backup DB (Postgres)
kubectl exec -n data postgres-0 -- pg_dump -U authentik authentik | gzip > authentik-$(date +%F).sql.gz
\`\`\`
```

- [ ] **Step 2: Commit**

```bash
git add apps/authentik/README.md
git commit -m "docs(authentik): add operational runbook"
git push origin main
```

---

## Task 11: Smoke test OIDC flow (manual)

**Files:** (không có file)

- [ ] **Step 1: Test authorize endpoint từ browser**

Mở URL (thay `<CLIENT_ID>`):
```
https://auth.cunghoclaptrinh.online/application/o/authorize/?response_type=code&client_id=<CLIENT_ID>&redirect_uri=https%3A%2F%2Fgoshop.cunghoclaptrinh.online%2Fapi%2Fauth%2Fcallback&scope=openid+profile+email+goshop-groups&state=test
```

Expected: redirect tới Authentik login → sau khi login (akadmin hoặc test user), redirect tới `goshop.cunghoclaptrinh.online/api/auth/callback?code=...&state=test` (sẽ 404 vì BE chưa có endpoint, OK ở phase này).

- [ ] **Step 2: Verify code response**

Trên trang 404 của goshop, kiểm tra URL có `code=<authcode>&state=test`.

Expected: có cả 2 query params → flow OIDC từ Authentik hoạt động đúng.

✅ Phase 1 hoàn tất. Authentik sẵn sàng cho Phase 2 (tích hợp `goshop-api` + `goshop-web`).

---

## Next Steps (Phase 2 — separate plan, repo `goshop`)

Sau khi Phase 1 này done, plan kế tiếp sẽ được viết trong repo `/Users/quangdang/Developers/src/quangdangfit/goshop`:

1. Implement OIDC client trong `goshop-api` (Go): authorize URL builder, callback handler, token exchange, JWKS verify, JIT user provisioning, session store qua Redis, RBAC middleware đọc `groups` claim.
2. Update `goshop-web`: bỏ form login/register, thêm login button → `/api/auth/login`, logout button.
3. Cập nhật `apps/goshop-api/externalsecret.yaml` ở deployment repo: thêm 3 keys `OIDC_CLIENT_ID`, `OIDC_CLIENT_SECRET`, `OIDC_ISSUER` (đã có sẵn ở Doppler từ Task 9 Step 7).
4. Cập nhật `apps/goshop-api/values.yaml`: thêm env `OIDC_*` từ secret.
5. Migrate user cũ (quyết định JIT vs bulk import).
6. Cleanup code login password-based.
