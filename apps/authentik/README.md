# Authentik

Single sign-on / OIDC provider cho Goshop.

- URL: https://auth.cunghoclaptrinh.online
- Namespace: `auth`
- Chart: `goauthentik/authentik` (version trong `application.yaml`)
- Data store: external Postgres (`postgres.data.svc.cluster.local`, DB `authentik`), Redis subchart riêng trong namespace.

## Secrets (Doppler)

- `AUTHENTIK_SECRET_KEY` — Django secret key, 64 hex chars.
- `AUTHENTIK_POSTGRES_PASSWORD` — password user DB `authentik`.
- `AUTHENTIK_BOOTSTRAP_PASSWORD` — password admin `akadmin` lần đầu.
- `AUTHENTIK_BOOTSTRAP_TOKEN` — API token cho automation.
- `GOSHOP_OIDC_CLIENT_ID` / `GOSHOP_OIDC_CLIENT_SECRET` / `GOSHOP_OIDC_ISSUER` — dùng bởi goshop-api (sau khi tạo provider).

## Bootstrap Postgres DB

Chạy 1 lần khi cài mới:

```bash
kubectl exec -it -n data postgres-0 -- psql -U postgres
```

```sql
CREATE USER authentik WITH PASSWORD '<từ Doppler AUTHENTIK_POSTGRES_PASSWORD>';
CREATE DATABASE authentik OWNER authentik;
GRANT ALL PRIVILEGES ON DATABASE authentik TO authentik;
```

## OIDC integration cho Goshop

- Provider name: `goshop-oidc`
- Application slug: `goshop`
- Redirect URI: `https://goshop.cunghoclaptrinh.online/api/v1/auth/callback`
- Scopes: `openid`, `profile`, `email`, `goshop-groups`
- Groups: `goshop-admin`, `goshop-user`

OIDC discovery: https://auth.cunghoclaptrinh.online/application/o/goshop/.well-known/openid-configuration

## Operations

```bash
# Logs
kubectl logs -n auth deploy/authentik-server -f
kubectl logs -n auth deploy/authentik-worker -f

# Restart sau khi đổi values
kubectl rollout restart -n auth deploy/authentik-server deploy/authentik-worker

# Backup DB
kubectl exec -n data postgres-0 -- pg_dump -U authentik authentik | gzip > authentik-$(date +%F).sql.gz
```
