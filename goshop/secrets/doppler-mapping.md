# Doppler → Kubernetes secret mapping

Doppler project: `goshop`
Environments: `dev`, `prod`

ESO `ClusterSecretStore` named `doppler` (defined in
`clusters/oke/platform/external-secrets.yaml`) authenticates with a service
token stored in `external-secrets/doppler-token` (seeded once during cluster bootstrap).

## Required Doppler keys

### Database (Postgres)
| Doppler key                     | Used by                                   |
|---------------------------------|-------------------------------------------|
| `POSTGRES_ADMIN_PASSWORD`       | `postgres-credentials.postgres-password`  |
| `POSTGRES_PASSWORD`             | `postgres-credentials.password`           |
| `POSTGRES_REPLICATION_PASSWORD` | `postgres-credentials.replication-password` |

### Cache (Redis)
| Doppler key      | Used by                          |
|------------------|----------------------------------|
| `REDIS_PASSWORD` | `redis-credentials.password`     |

### App (goshop)
| Doppler key                    | Purpose                                          |
|--------------------------------|--------------------------------------------------|
| `DATABASE_URI`                 | Postgres DSN — `postgres://goshop:$PASS@postgresql.data.svc.cluster.local:5432/goshop?sslmode=disable` |
| `REDIS_URI`                    | `redis://default:$PASS@redis-master.data.svc.cluster.local:6379` |
| `AUTH_SECRET`                  | Session/auth signing key                          |
| `JWT_SECRET`                   | JWT signing key                                  |
| `OTEL_EXPORTER_OTLP_ENDPOINT`  | `http://tempo.monitoring.svc:4318`               |

### Platform extras
| Doppler key             | Purpose                                            |
|-------------------------|----------------------------------------------------|
| `GRAFANA_ADMIN_PASSWORD`| Grafana admin password (consumed via `grafana-admin` ESO) |
| `DISCORD_WEBHOOK_URL`   | Alertmanager → Discord webhook                     |

## How the values flow

1. You set the value in Doppler.
2. ESO syncs to a Kubernetes `Secret` in the target namespace (every 1h).
3. The chart's pod loads the Secret via `envFrom: secretRef`.

## When you add a new secret

1. Add the key to Doppler in BOTH `dev` and `prod`.
2. Add the key to `externalSecret.keys` in `charts/goshop/values.yaml`.
3. Commit & push — ArgoCD applies, ESO refreshes within an hour, deployment rolls.
