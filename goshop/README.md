# GoShop Deployment

Production-style GitOps deployment for [`quangdangfit/goshop`](https://github.com/quangdangfit/goshop) on Oracle Cloud Always-Free (OKE), driven from this repo: <https://github.com/quangdangfit/deployment>.

This document is the concrete execution plan derived from [`devops-plan.md`](./devops-plan.md). The plan covers stack rationale and Oracle quotas — this README is the actionable checklist + repository layout.

---

## 0. Conventions

- **Code repo (app):** `quangdangfit/goshop` — Go 1.26, Gin, GORM, ports 8888 (REST) / 8889 (gRPC), config in `pkg/config/config.yaml`, entrypoint `cmd/api/main.go`. Already has `Dockerfile`, `Makefile`, `docker-compose.yaml`, `.github/workflows/`.
- **Deploy repo (this):** `quangdangfit/deployment` — monorepo for all personal-project deployments. Each project is a top-level folder.
- **Cluster:** single OKE cluster, multi-tenant by namespace (`goshop`, `monitoring`, `argocd`, …). Other future projects share the same cluster.
- **Domain placeholder:** `goshop.<your-domain>` — replace before apply.

---

## 1. Repository Layout (`quangdangfit/deployment`)

```
deployment/
├── README.md                           # mono-repo index
├── .gitignore
├── clusters/                           # shared infra — sibling of project dirs
│   └── oke/
│       ├── infra/                      # OpenTofu — VCN, OKE, IAM, Object Storage
│       │   ├── providers.tf
│       │   ├── backend.tf              # S3-compat → OCI Object Storage
│       │   ├── vcn.tf
│       │   ├── oke.tf
│       │   ├── iam.tf
│       │   ├── object-storage.tf
│       │   ├── variables.tf
│       │   ├── outputs.tf
│       │   └── terraform.tfvars.example
│       ├── bootstrap/                  # one-shot installs before ArgoCD takes over
│       │   ├── README.md
│       │   └── argocd/values.yaml
│       └── platform/                   # ArgoCD App-of-Apps for shared infra
│           ├── root.yaml
│           ├── ingress-nginx.yaml
│           ├── cert-manager.yaml
│           ├── cluster-issuer.yaml
│           ├── external-secrets.yaml
│           ├── kyverno.yaml
│           ├── kyverno-verify-images.yaml
│           ├── kube-prometheus-stack.yaml
│           ├── prometheus-rules.yaml
│           ├── grafana-dashboards.yaml
│           ├── loki.yaml
│           ├── tempo.yaml
│           ├── velero.yaml
│           ├── argocd-notifications.yaml
│           └── argocd-project.yaml     # AppProject `goshop`
└── goshop/                             # per-project: workloads only
    ├── README.md                       # this doc
    ├── devops-plan.md
    ├── apps/                           # ArgoCD Applications for goshop workloads
    │   ├── root.yaml                   # App-of-Apps root for goshop project
    │   ├── application.yaml            # the goshop Helm chart
    │   ├── postgresql.yaml             # Bitnami chart
    │   ├── redis.yaml                  # Bitnami chart
    │   └── postgres-backup.yaml        # wraps manifests/postgres-backup/
    ├── manifests/
    │   └── postgres-backup/            # raw resources (CronJob + ESO)
    │       └── cronjob.yaml
    ├── charts/
    │   └── goshop/                     # Helm chart (Chart.name must equal dir name)
    │       ├── Chart.yaml
    │       ├── values.yaml
    │       ├── values-dev.yaml
    │       ├── values-prod.yaml
    │       └── templates/...
    ├── secrets/
    │   └── doppler-mapping.md          # which Doppler keys → which env vars
    └── runbooks/
        ├── restore-postgres.md
        ├── rotate-credentials.md
        └── incident-response.md
```

Rationale: `clusters/` lives at the **repo root** because the OKE cluster is shared — `goshop` today, `blog`/etc tomorrow. Per-project folders own only their namespace, chart, and Applications. Adding a new project = drop in `deployment/<project>/`; the cluster doesn't move.

---

## 2. Phase Checklist

Each phase below points back to `devops-plan.md` for context. Track progress by checking boxes in PRs.

### Phase 0 — Prerequisites
- [ ] OCI account + Budget Alert at $1
- [ ] Verified ARM A1.Flex capacity in target region (test create + terminate one VM)
- [ ] OCI compartment `goshop-cluster` + IAM user `tofu` with API key
- [ ] Doppler/Infisical project `goshop` with envs `dev`, `prod`
- [ ] Domain ready (DuckDNS subdomain or Cloudflare zone)
- [ ] GitHub repo `quangdangfit/deployment` created (this one)
- [ ] Local tools: `opentofu`, `kubectl`, `helm`, `oci`, `argocd`, `cosign`, `trivy`, `k9s`

### Phase 1 — Provision (`clusters/oke/infra`)
- [x] OpenTofu module skeleton authored (`providers.tf`, `vcn.tf`, `oke.tf`, `iam.tf`, `object-storage.tf`, `outputs.tf`, `terraform.tfvars.example`)
- [ ] Manually create `tofu-state` bucket in OCI Object Storage and edit `backend.tf` (replace `REPLACE_NAMESPACE`)
- [ ] Copy `terraform.tfvars.example` → `terraform.tfvars` and fill in OCIDs / SSH key
- [ ] `tofu init && tofu apply`
- [ ] `oci ce cluster create-kubeconfig …` → `kubectl get nodes` shows 2× Ready

### Phase 2 — Cluster bootstrap (`clusters/oke/bootstrap` → `platform/`)
- [x] Bootstrap script + ArgoCD `values.yaml` authored (`bootstrap/README.md`, `bootstrap/argocd/values.yaml`)
- [x] Platform App-of-Apps authored: `root.yaml`, `ingress-nginx`, `cert-manager`, `cluster-issuer`, `external-secrets`, `kyverno`, `kube-prometheus-stack`, `loki`, `tempo`, `velero`
- [ ] Run namespace creation + GHCR pull secret + Doppler token seed (per `bootstrap/README.md`)
- [ ] `helm install argocd …` with `bootstrap/argocd/values.yaml`
- [ ] `kubectl apply -f clusters/oke/platform/root.yaml` → App-of-Apps takes over
- [ ] Verify each platform Application is `Synced/Healthy` in ArgoCD UI
- [ ] Point DNS wildcard `*.goshop.quangdang.dev` → ingress-nginx LB external IP
- [ ] `ClusterIssuer letsencrypt-prod` issues a real cert for `argocd.goshop.quangdang.dev`

### Phase 3 — App repo changes (PR against `quangdangfit/goshop`)
- [ ] Replace existing `Dockerfile` with multi-stage, multi-arch (linux/arm64 + linux/amd64), distroless, non-root — see plan §3.1
- [ ] Add `/health` (liveness, no deps) and `/ready` (DB + Redis ping) endpoints
- [ ] Add `/metrics` (Prometheus) middleware for Gin
- [ ] OpenTelemetry instrumentation (HTTP, gRPC, GORM) → OTLP env-var configurable
- [ ] Trim `.dockerignore` to exclude tests, mocks, web build artifacts not needed at runtime
- [ ] Replace `.github/workflows/ci.yml` with: lint → test (services: postgres, redis) → build/push GHCR (multi-arch) → Trivy → SBOM → cosign keyless sign

### Phase 4 — Helm chart (`goshop/charts/goshop`)
- [x] `Chart.yaml` (appVersion mirrors goshop tag)
- [x] `values.yaml` with image, two `containerPorts`, resources (requests 100m/128Mi, limits 500m/256Mi), probes
- [x] `deployment.yaml` — securityContext: runAsNonRoot, readOnlyRootFilesystem, drop ALL caps; mounts ConfigMap at `/etc/goshop/config.yaml`
- [x] `service.yaml` — two named ports `http` 8888, `grpc` 8889
- [x] `ingress-http.yaml` — `api.goshop.quangdang.dev`, cert-manager annotation
- [x] `ingress-grpc.yaml` — `grpc.goshop.quangdang.dev`, `nginx.ingress.kubernetes.io/backend-protocol: GRPC`
- [x] `hpa.yaml` — 2–5 replicas, CPU 70%
- [x] `pdb.yaml` — `minAvailable: 1`
- [x] `servicemonitor.yaml` — scrape `/metrics` on `http` port
- [x] `externalsecret.yaml` — synthesize `DATABASE_URI`, `REDIS_URI`, `AUTH_SECRET`, `JWT_SECRET`, `OTEL_EXPORTER_OTLP_ENDPOINT` from Doppler
- [x] `migration-job.yaml` — PreSync hook, sync-wave `-1`. Command currently `["/goshop", "--migrate-only"]` — verify against actual goshop CLI
- [x] `networkpolicy.yaml` — ingress only from `ingress-nginx`/`monitoring`; egress to `data` namespace + DNS + 443 + OTLP
- [x] `configmap.yaml` — renders `.Values.config` as `/etc/goshop/config.yaml`
- [ ] Smoke-test with `kind`: `helm template` clean, `helm install -f values-dev.yaml` green

### Phase 5 — Data layer (`goshop/apps/postgresql.yaml`, `redis.yaml`)
- [x] Postgres ArgoCD Application + ESO `postgres-credentials` (Bitnami chart, 20Gi, ServiceMonitor on, daily logical backup CronJob)
- [x] Redis ArgoCD Application + ESO `redis-credentials` (Bitnami chart, 5Gi, ServiceMonitor on)
- [x] Velero daily schedule wired in `platform/velero.yaml` (namespaces `data` + `goshop`, TTL 7d)
- [x] Restore drill runbook in `runbooks/restore-postgres.md`
- [ ] Add CronJob `pg_dump` → OCI Object Storage (paranoia long-term backup)

### Phase 6 — GitOps loop (`goshop/apps/application.yaml`)
- [x] ArgoCD Application points at `goshop/charts/goshop` with `values.yaml` + `values-prod.yaml`
- [x] ArgoCD Image Updater annotations: track `ghcr.io/quangdangfit/goshop`, strategy `digest`, allow `^master$`, write-back to `values-prod.yaml`
- [ ] Apply once cluster is up; verify push-to-master triggers digest write-back commit
- [ ] Kyverno policy `verify-images` enforces cosign signature with GitHub OIDC issuer (TODO add policy)

### Phase 7 — Observability (lives in `clusters/oke/platform`)
- [x] kube-prometheus-stack with Grafana ingress + persistent storage
- [x] Loki single-binary + Promtail
- [x] Tempo single-binary
- [x] Alertmanager → Discord webhook receiver wired (URL from Doppler `DISCORD_WEBHOOK_URL`)
- [x] `prometheus-rules.yaml` — concrete `PrometheusRule` set (5xx>1%, p99>1s, PVC>80%, cert<14d, pod crashloop, pg/redis down, pg connection saturation)
- [x] `argocd-notifications.yaml` — sync-failed / health-degraded → Discord with embed cards
- [x] Grafana dashboard ConfigMap stubs (`grafana-dashboards.yaml`) — sidecar auto-loads; replace JSON bodies with real exports from grafana.com (6671 Go runtime, etc.)
- [ ] Replace dashboard JSON stubs with real exports

### Phase 8 — Hardening
- [x] Kyverno baseline policies (require resources, no `:latest`, runAsNonRoot) in `kyverno.yaml`
- [x] Kyverno cosign verify-images policy (`kyverno-verify-images.yaml`, currently `Audit` — flip to `Enforce` once CI signs reliably)
- [x] AppProject `goshop` scoped to deploy repo + Bitnami repo / namespaces `goshop`, `data`, `argocd`
- [x] Long-term off-cluster `pg_dump` CronJob → OCI Object Storage (`manifests/postgres-backup/cronjob.yaml`)
- [ ] Renovate Bot configured for chart deps + Go modules
- [ ] Default-deny NetworkPolicy per namespace
- [ ] Multi-env via ApplicationSet (`dev` + `prod` namespace, same chart, different values)
- [ ] Argo Rollouts canary for goshop deploy
- [ ] OpenCost for in-cluster cost visibility

---

## 3. Defaults committed (swap any time via values / vars)

| Decision | Default chosen | Where to change |
|---|---|---|
| Domain | `goshop.quangdang.dev` (with `api.`, `grpc.`, `argocd.`, `grafana.` subdomains) | `charts/goshop/values.yaml` + `clusters/oke/platform/*.yaml` |
| OCI region | `ap-singapore-1` | `clusters/oke/infra/variables.tf` + `backend.tf` |
| Secrets backend | Doppler (`ClusterSecretStore` named `doppler`) | `clusters/oke/platform/external-secrets.yaml` |
| Frontend (`web/`) | **skipped** — API only | add separate chart later if/when needed |
| gRPC | publicly exposed via `grpc.goshop.quangdang.dev` | `values.yaml.ingress.grpc.enabled` |
| Migrations | run as PreSync Job, command `["/goshop", "--migrate-only"]` | `values.yaml.migration.command` (verify against goshop CLI flags) |
| Image tag strategy | `master` + digest write-back via Image Updater | `apps/application.yaml` annotations |
| Alert sink | Discord webhook | Doppler key `DISCORD_WEBHOOK_URL` (consumed by Alertmanager) |
| Backup retention | Velero 7d + Bitnami daily logical backup; long-term `pg_dump` to Object Storage = TODO | `platform/velero.yaml`, `apps/postgresql.yaml` |
| Deploy repo visibility | public (`https://github.com/quangdangfit/deployment`) | `apps/*.yaml` `repoURL` |
| OCI free-tier risk | accepted (single-region, ARM-only) | n/a |

## 4. Things still missing — needs your action / info

1. **Doppler service token** — generate it once, you'll seed it in `external-secrets/doppler-token` (see `clusters/oke/bootstrap/README.md`).
2. **Doppler key list** — populate every key in `secrets/doppler-mapping.md` for both `dev` and `prod`.
3. **Goshop CLI verb for migrations** — confirm whether `goshop --migrate-only` is real; if not, update `charts/goshop/values.yaml#migration.command` to the right invocation. `cmd/api/main.go` likely needs a flag/sub-command added in the upstream goshop repo.
4. **App changes upstream (`quangdangfit/goshop`)** — Phase 3 in section 2: replace Dockerfile, add `/health`, `/ready`, `/metrics`, OTel SDK, and the new CI workflow with cosign keyless. Those land in the **app repo**, not this one.
5. **`backend.tf` namespace placeholder** — replace `REPLACE_NAMESPACE` in `clusters/oke/infra/backend.tf` and `clusters/oke/platform/velero.yaml` with the value from `oci os ns get`.
6. **Email for ACME registration** — `clusters/oke/platform/cluster-issuer.yaml` currently uses `quangdangfit@gmail.com`; swap if you want a different one.
7. **OCI tenancy/user OCIDs + API key fingerprint** — fill in `terraform.tfvars` (file gitignored).
8. **DNS provider** — pick a registrar. The chart hard-codes `goshop.quangdang.dev`; if you go with DuckDNS or a different domain, do a global find-replace in this repo.

---

## 5. Quick start (once gaps above are filled)

All paths below are from the repo root.

```bash
# 1. provision
cd clusters/oke/infra
tofu init && tofu apply

# 2. kubeconfig
oci ce cluster create-kubeconfig --cluster-id "$(tofu output -raw cluster_id)" \
  --region "$(tofu output -raw region)" --token-version 2.0.0 --kube-endpoint PUBLIC_ENDPOINT
cd ../../..

# 3. bootstrap argocd
kubectl create ns argocd
helm install argocd argo/argo-cd -n argocd -f clusters/oke/bootstrap/argocd/values.yaml

# 4. seed GHCR pull secret + ESO token (see clusters/oke/bootstrap/README.md)

# 5. hand control to GitOps — platform first (ingress, cert-manager, ESO, observability),
#    then goshop apps once platform is Healthy
kubectl apply -f clusters/oke/platform/root.yaml
kubectl apply -f goshop/apps/root.yaml
```

From that point, every push to `master` on `quangdangfit/goshop` produces a new signed image, Image Updater commits the digest into this repo, and ArgoCD rolls it out.
