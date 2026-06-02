# Goshop Observability — Design

**Date**: 2026-06-02
**Scope**: Wire goshop (api + web) and the Postgres/Redis it depends on into the existing platform observability stack (Prometheus + Tempo + Grafana, namespace `monitoring`).

**Out of scope**: Logs (Loki — deferred pending object storage decision). Alerting (Alertmanager routing — deferred until base metrics/traces are flowing).

## Goals

1. See infra-level health of Postgres and Redis (connections, slow queries, memory, evictions).
2. See app-level RED metrics (Rate, Errors, Duration) per HTTP route of goshop-api.
3. See distributed traces of a request flowing through web → api → Postgres/Redis, with 10% sampling.
4. Auto-generated service graph in Grafana.

## Non-Goals

- 100% trace sampling — too expensive on the single-node 10Gi Tempo PVC.
- Tail-based sampling / OTel Collector — adds a component for marginal benefit at current traffic.
- Custom business metrics (orders/payments) — can be added later once the plumbing is in place.
- Logs aggregation.
- Alert routing to Discord/Telegram.

## Architecture

```
[React web (browser)]
    │  OTLP/HTTP traces (10% sample)
    ▼
https://tempo-otlp.cunghoclaptrinh.online  ──► ingress-nginx ──► tempo:4318
                                                                       ▲
[goshop-api gin :8888]                                                 │
    ├── /metrics  ────────────────► Prometheus (ServiceMonitor)        │
    ├── OTLP gRPC ──────────────────────────────────────► tempo:4317 ──┘
    └── otelgin + otelpgx + otelredis spans

[postgres StatefulSet, ns=data]
    └── sidecar postgres_exporter :9187 ──► Prometheus (ServiceMonitor)

[redis Deployment, ns=data]
    └── sidecar redis_exporter :9121 ──► Prometheus (ServiceMonitor)

[Tempo metrics-generator] ──► remote_write ──► Prometheus
                              (service graph + span metrics)

[Grafana] ──► Prometheus + Tempo datasources (already provisioned)
```

## Decisions

| Decision | Choice | Reason |
|---|---|---|
| Postgres exporter auth | Dedicated user `postgres_exporter` with `pg_monitor` role | Principle of least privilege; superuser scrape is a footgun |
| Redis exporter auth | Reuse existing `REDIS_PASSWORD` from ExternalSecret | No read-only role concept in Redis at this scale |
| Trace sampling | `parentbased_traceidratio` @ 0.1 (10%) | Storage budget on 10Gi PVC; head sampling is simplest |
| Metrics port for goshop-api | Same `:8888` as app, path `/metrics` | Internal ClusterIP only; no exposure risk; one less port to wire |
| Browser → Tempo path | New ingress `tempo-otlp.cunghoclaptrinh.online` (OTLP/HTTP) | Browser can't hit ClusterIP; HTTP needed since gRPC-web is awkward |
| Tempo deployment mode | Stay monolithic (already deployed) | Single-node; metrics-generator works in monolithic too |
| Where exporter manifests live | Co-located: `platform/databases/{postgres,redis}/manifests/` | Matches flat-layout preference; one folder per DB owns everything for that DB |

## Components

### 1. Postgres exporter

- **Image**: `quay.io/prometheuscommunity/postgres-exporter` (multi-arch, ARM64 OK)
- **Deployment shape**: sidecar in the existing `postgres` StatefulSet pod
  - Shares network namespace → connects to `localhost:5432`
  - Dies with the DB pod (correct lifecycle)
- **User provisioning**: one-shot Job `postgres-exporter-user-init` that runs on apply, executes:
  ```sql
  CREATE USER postgres_exporter WITH PASSWORD '<from-doppler>';
  GRANT pg_monitor TO postgres_exporter;
  ```
  Idempotent (`CREATE USER IF NOT EXISTS` via DO block).
- **Credential**: new Doppler key `POSTGRES_EXPORTER_PASSWORD`. The existing `postgres-secrets` ExternalSecret gets a new field; sidecar reads `DATA_SOURCE_NAME` constructed from envs.
- **Service**: extend existing `postgres` Service with port `metrics:9187`.
- **ServiceMonitor**: scrape interval 30s, path `/metrics`.

### 2. Redis exporter

- **Image**: `oliver006/redis_exporter` (multi-arch)
- **Sidecar** in the redis Deployment pod
- **Env**: `REDIS_ADDR=redis://localhost:6379`, `REDIS_PASSWORD` from existing ExternalSecret
- **Service**: extend `redis` Service with port `metrics:9121`
- **ServiceMonitor**: scrape interval 30s

### 3. goshop-api instrumentation (Go / gin)

Code changes in the goshop application repo (separate PR; tracked here for context).

- **Dependencies**:
  - `github.com/prometheus/client_golang/prometheus/promhttp`
  - `github.com/zsais/go-gin-prometheus` (or hand-rolled middleware — preference: hand-rolled, ~30 LOC)
  - `go.opentelemetry.io/otel` + `otel/sdk` + `otel/exporters/otlp/otlptrace/otlptracegrpc`
  - `go.opentelemetry.io/contrib/instrumentation/github.com/gin-gonic/gin/otelgin`
  - `github.com/exaring/otelpgx` (if using pgx) **or** `go.nhat.io/otelsql` (if using database/sql)
  - `github.com/redis/go-redis/extra/redisotel/v9`
- **Metrics**: middleware records `http_requests_total{method,route,status}` and `http_request_duration_seconds` histogram (labels: method, route, status). Route label is gin's matched pattern (not raw path) to avoid cardinality explosion.
- **`/metrics` endpoint**: served on the same gin engine at `/metrics`. ServiceMonitor scrapes `:8888/metrics`.
- **Tracing init**: at startup, configure OTel TracerProvider with:
  - Exporter: OTLP gRPC → `tempo.monitoring.svc.cluster.local:4317`, insecure (in-cluster)
  - Resource: `service.name=goshop-api`, `service.version=<git-sha>`, `deployment.environment=production`
  - Sampler: `ParentBased(TraceIDRatioBased(0.1))`
  - Propagator: composite W3C TraceContext + Baggage
- **Auto-instrumentation wiring**:
  - `r.Use(otelgin.Middleware("goshop-api"))` — creates root span per request
  - pgx: `otelpgx.NewTracer()` on the pool config
  - redis: `redisotel.InstrumentTracing(client)`
- **Config via env** (set in `apps/goshop-api/values.yaml`):
  - `OTEL_EXPORTER_OTLP_ENDPOINT=http://tempo.monitoring.svc.cluster.local:4317`
  - `OTEL_EXPORTER_OTLP_PROTOCOL=grpc`
  - `OTEL_SERVICE_NAME=goshop-api`
  - `OTEL_TRACES_SAMPLER=parentbased_traceidratio`
  - `OTEL_TRACES_SAMPLER_ARG=0.1`
- **gRPC server (:8889)**: also wrap with `otelgrpc.UnaryServerInterceptor()` so internal gRPC calls get traced.

### 4. goshop-web instrumentation (React)

- **Dependencies**:
  - `@opentelemetry/sdk-trace-web`
  - `@opentelemetry/exporter-trace-otlp-http`
  - `@opentelemetry/instrumentation-fetch`
  - `@opentelemetry/instrumentation-xml-http-request`
  - `@opentelemetry/context-zone`
- **Init**: in app entry (before any fetch), configure:
  - Exporter: OTLP/HTTP → `https://tempo-otlp.cunghoclaptrinh.online/v1/traces`
  - Resource: `service.name=goshop-web`
  - Sampler: `TraceIdRatioBasedSampler(0.1)`
  - Fetch instrumentation `propagateTraceHeaderCorsUrls: [/goshop\.cunghoclaptrinh\.online/]` so `traceparent` is sent on API calls
- **CORS**: ingress for `tempo-otlp.cunghoclaptrinh.online` must allow `Origin: https://goshop.cunghoclaptrinh.online` and headers `traceparent, tracestate, content-type`.

### 5. Tempo changes

`platform/tempo/values.yaml` — enable metrics-generator:

```yaml
tempo:
  metricsGenerator:
    enabled: true
    remoteWriteUrl: http://kube-prometheus-stack-prometheus.monitoring.svc:9090/api/v1/write
config: |
  ...
  overrides:
    defaults:
      metrics_generator:
        processors: [service-graphs, span-metrics]
```

`platform/tempo/ingress-otlp.yaml` — new ingress:

- Host: `tempo-otlp.cunghoclaptrinh.online`
- Backend: `tempo:4318` (OTLP/HTTP)
- Annotations: cert-manager letsencrypt-prod; CORS allow origin `https://goshop.cunghoclaptrinh.online`; allow methods `POST, OPTIONS`; allow headers `content-type, traceparent, tracestate`.

### 6. Prometheus changes

`platform/prometheus/values.yaml` — enable remote write receiver so Tempo metrics-generator can push:

```yaml
prometheus:
  prometheusSpec:
    enableFeatures:
      - remote-write-receiver
```

### 7. Grafana dashboards

`platform/grafana/values.yaml` — add to `dashboards.default`:

- `postgres-overview`: gnetId 9628
- `redis-overview`: gnetId 763
- `goshop-api-red`: a custom dashboard (committed as JSON to `platform/grafana/dashboards/goshop-api-red.json`, loaded via sidecar). Panels:
  - Requests/sec by route
  - Error rate (% 5xx)
  - p50 / p95 / p99 latency by route
  - In-flight requests
  - Trace exemplars on the latency panels (auto-link to Tempo)
- Service graph: auto-rendered in Grafana's Tempo datasource explore (no dashboard needed once metrics-generator is on).

## Data flow — request trace example

1. User clicks "Place order" in React → fetch instrumentation creates a span, generates `traceparent` header, attaches to request.
2. fetch fires async → exporter batches and POSTs to `tempo-otlp.cunghoclaptrinh.online/v1/traces` (10% chance) — non-blocking.
3. API request reaches ingress-nginx → goshop-api gin handler.
4. `otelgin` middleware sees `traceparent`, creates child span continuing the trace.
5. Handler queries Postgres via pgx → `otelpgx` creates a span as child of the gin span. SQL recorded in span attributes.
6. Handler hits Redis → `redisotel` creates another child span.
7. Response sent. gin middleware finishes its span; exporter batches → OTLP gRPC to Tempo (10% chance based on root sampling decision propagated).
8. Tempo metrics-generator extracts span metrics + builds service graph edges from `goshop-web → goshop-api → postgres/redis`.
9. Grafana exemplars on the histogram show clickable trace IDs.

## File layout

```
platform/databases/postgres/
  externalsecret.yaml                       (modify: + POSTGRES_EXPORTER_PASSWORD)
  manifests/sts.yaml                        (modify: + sidecar)
  manifests/svc.yaml                        (modify: + metrics port)
  manifests/exporter-user-init-job.yaml     (new)
  manifests/servicemonitor.yaml             (new)

platform/databases/redis/
  manifests/deploy.yaml                     (modify: + sidecar)
  manifests/svc.yaml                        (modify: + metrics port)
  manifests/servicemonitor.yaml             (new)

platform/databases/apply.sh                 (modify: apply new job + servicemonitors)

platform/tempo/
  values.yaml                               (modify: metrics-generator)
  ingress-otlp.yaml                         (new)
  install.sh                                (modify: kubectl apply ingress-otlp.yaml)

platform/prometheus/
  values.yaml                               (modify: remote-write-receiver)

platform/grafana/
  values.yaml                               (modify: + 3 dashboards)
  dashboards/goshop-api-red.json            (new)

apps/goshop-api/
  values.yaml                               (modify: + OTEL env vars)
  servicemonitor.yaml                       (new)
  apply.sh / application.yaml               (modify if needed to apply servicemonitor)
```

Plus separate PR in the goshop application repo for the Go code changes.

## Testing / verification

After each phase, verify before moving on.

**Phase 1 (DB exporters)**:
- `kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090`, query:
  - `up{job="postgres"}` → 1
  - `up{job="redis"}` → 1
  - `pg_up == 1`
  - `redis_up == 1`
- Grafana → Postgres dashboard renders with real numbers, not "No data".

**Phase 2 (api metrics)**:
- `curl http://goshop-api.<ns>.svc:8888/metrics` from an in-cluster pod → see `http_requests_total`.
- Generate traffic; query `rate(http_requests_total{service="goshop-api"}[1m])` → non-zero.
- "Goshop API RED" dashboard shows live panels.

**Phase 3 (tracing)**:
- Generate traffic; Grafana → Explore → Tempo → Search → see traces with service `goshop-api`.
- Open a trace → see spans for gin → pgx → redis nested.
- From browser: open devtools → Network → see `traceparent` header on API calls.
- Tempo → Service Graph → see edges `goshop-web → goshop-api → postgres`, `→ redis`.

## Risks

- **Cardinality explosion** if `route` label uses raw URL paths instead of matched gin pattern. Mitigated by using `c.FullPath()` in middleware.
- **Tempo PVC fill-up** at 10% with growing traffic. Retention is 168h; monitor PVC usage; reduce sample rate if needed.
- **Browser → Tempo CORS misconfig**: most likely failure point. Test from browser devtools before declaring done.
- **postgres_exporter user creation race**: Job runs before the user exists in DB. Job must be idempotent and tolerate "already exists".
- **OTLP gRPC client retries can stall app shutdown**: configure batch span processor with reasonable `BatchTimeout` and ensure `Shutdown(ctx)` has a deadline.

## Phased rollout

1. **Phase 1** (no app code change, low risk): Postgres + Redis exporters, ServiceMonitors, import dashboards. Ship and verify.
2. **Phase 2** (goshop-api code PR): metrics middleware + `/metrics` + ServiceMonitor + RED dashboard. Ship and verify.
3. **Phase 3a** (goshop-api code PR): OTel SDK + auto-instrumentation, Tempo metrics-generator, Prometheus remote-write receiver. Verify traces in Grafana.
4. **Phase 3b** (goshop-web code PR + new ingress): browser SDK, OTLP ingress, CORS. Verify end-to-end trace from browser to DB.

Each phase is independently revertable.
