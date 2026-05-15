# Phase 9 — Production hardening

## Mục tiêu

Sau 8 phase mình có hệ thống chạy và auto-deploy. Phase này nâng cấp để "an toàn để chạy thật": backup, scaling, isolation, observability.

Đây là phase **mở** — mỗi mục có thể là 1 phase phụ riêng. Khuyến nghị làm tuần tự, làm xong mục nào commit + verify mục đó trước khi sang mục sau.

## Checklist hardening

| Mục | Mục đích | Độ ưu tiên |
|---|---|---|
| 9.1 [Postgres backup](#91-postgres-backup) | Khôi phục được sau khi mất data | **Cao** |
| 9.2 [Resource limits + HPA](#92-resource-limits--hpa) | Không 1 pod ăn hết RAM, scale khi load tăng | **Cao** |
| 9.3 [PodDisruptionBudget (PDB)](#93-poddisruptionbudget) | Không downtime khi node drain | Trung |
| 9.4 [NetworkPolicy](#94-networkpolicy) | Hạn chế pod nào gọi pod nào | Trung |
| 9.5 [SecurityContext](#95-securitycontext) | Pod chạy non-root, read-only FS | Trung |
| 9.6 [Monitoring (Prometheus + Grafana)](#96-monitoring) | Thấy metrics, alert khi sự cố | Trung |
| 9.7 [Restore drill](#97-restore-drill) | Verify backup thực sự khôi phục được | **Cao** |

---

## 9.1 Postgres backup

### Tại sao

PV local-path = thư mục trên VM. Mất VM = mất hết. Cần backup ra **storage độc lập**.

### Phương án

| Phương án | Setup | Lưu ở đâu |
|---|---|---|
| `pg_dump` CronJob → Cloudflare R2 / Backblaze B2 (S3-compatible) | Easy | Object storage (~$0.015/GB/tháng) |
| `pg_basebackup` + WAL archiving | Medium | Object storage, RPO < 1 phút |
| Snapshot disk OCI | Easy nhưng giới hạn | Cloud snapshot — chỉ rollback toàn disk |
| pgBackRest | Mạnh, repo trên S3 | Object storage, point-in-time recovery |

→ Phase này dùng **pg_dump CronJob** (đơn giản, đủ cho RPO 24h).

### Manifest

Xem `manifests/9.1-pg-backup-cronjob.yaml`. CronJob chạy mỗi 02:00:
1. Exec `pg_dump goshop > /tmp/dump.sql.gz`
2. Upload với `aws s3 cp` (s3-compatible CLI) lên bucket
3. Retention: bucket lifecycle policy giữ 30 ngày

Cần Secret `s3-backup-creds` (access key, secret key, endpoint, bucket).

### Apply

```bash
# Thêm Doppler keys: S3_ACCESS_KEY, S3_SECRET_KEY, S3_ENDPOINT, S3_BUCKET
# Apply ExternalSecret trỏ vào (đặt trong manifests/9.1-pg-backup-externalsecret.yaml)
kubectl apply -f manifests/9.1-pg-backup-externalsecret.yaml
kubectl apply -f manifests/9.1-pg-backup-cronjob.yaml

# Force chạy thử ngay (thay vì đợi 02:00):
kubectl -n data create job pg-backup-test --from=cronjob/pg-backup

# Theo dõi:
kubectl -n data logs job/pg-backup-test
```

---

## 9.2 Resource limits + HPA

### Resource limits

Đã có sẵn ở chart goshop (`values.yaml`). Quy tắc:
- `requests` = "minimum guaranteed" — k8s đặt pod vào node có đủ tài nguyên
- `limits` = "absolute max" — pod vượt = throttle (CPU) hoặc OOMKill (memory)

→ Đặt limits ~2x requests cho buffer. Đo bằng `kubectl top pod` sau khi chạy 1 tuần.

### HPA — Horizontal Pod Autoscaler

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: goshop
  namespace: goshop
spec:
  scaleTargetRef: { apiVersion: apps/v1, kind: Deployment, name: goshop }
  minReplicas: 2
  maxReplicas: 5
  metrics:
    - type: Resource
      resource:
        name: cpu
        target: { type: Utilization, averageUtilization: 70 }
```

K3s đã bundle metrics-server (verify `kubectl top nodes`). Nếu chưa thì HPA không hoạt động.

Apply:
```bash
kubectl apply -f manifests/9.2-goshop-hpa.yaml
kubectl -n goshop get hpa goshop -w
```

→ Phase 9 nên đặt HPA vào chart goshop (template `hpa.yaml` có condition `if .Values.hpa.enabled`).

---

## 9.3 PodDisruptionBudget

Khi drain node (vd update k3s, reboot), k8s sẽ evict pod. PDB nói "phải còn tối thiểu X pod Ready":

```yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: goshop
spec:
  minAvailable: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: goshop
```

Khi `replicas: 2` + `minAvailable: 1` → drain tuần tự, 1 pod xuống cùng lúc, không downtime.

Single-node cluster ít dùng — PDB có nghĩa nhất khi có ≥ 2 node.

---

## 9.4 NetworkPolicy

Mặc định mọi pod gọi mọi pod được. NetworkPolicy = firewall cho pod, default-deny + allow whitelist.

**Cần CNI hỗ trợ:** k3s mặc định dùng flannel — KHÔNG hỗ trợ NetworkPolicy. Phải:
- Đổi CNI sang Calico/Cilium (re-install k3s với `--flannel-backend=none --disable-network-policy=false`), hoặc
- Bỏ qua phase này nếu chấp nhận risk

```yaml
# Cho phép pod app gọi postgres:
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: postgres-allow-from-goshop
  namespace: data
spec:
  podSelector: { matchLabels: { app: postgres } }
  policyTypes: [Ingress]
  ingress:
    - from:
        - namespaceSelector:
            matchLabels: { kubernetes.io/metadata.name: goshop }
      ports:
        - protocol: TCP
          port: 5432
```

---

## 9.5 SecurityContext

Mặc định pod chạy root. Production-grade pod nên:
```yaml
spec:
  template:
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
        fsGroup: 1000
        seccompProfile: { type: RuntimeDefault }
      containers:
        - name: goshop
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: [ALL]
```

→ App có thể fail nếu cần write `/tmp` — mount `emptyDir` cho `/tmp`. Test kỹ trước khi apply.

Goshop image dùng `alpine` base + chạy `/app/goshop` — verify UID trong Dockerfile, có thể cần thêm USER directive.

---

## 9.6 Monitoring

### kube-prometheus-stack

1 chart Helm gói:
- Prometheus (scraper + TSDB)
- Grafana (UI)
- Alertmanager
- node-exporter (host metrics)
- kube-state-metrics (k8s object state)

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm upgrade --install kps prometheus-community/kube-prometheus-stack \
  -n monitoring --create-namespace \
  --set grafana.adminPassword=changeme \
  --set prometheus.prometheusSpec.retention=15d \
  --set prometheus.prometheusSpec.resources.requests.memory=512Mi
```

Expose Grafana qua Ingress (`monitoring.cunghoclaptrinh.online`).

### App metrics

Goshop có `/metrics` (Prometheus format) không? Kiểm tra code. Nếu chưa, thêm middleware Gin + `github.com/prometheus/client_golang`. Sau đó tạo `ServiceMonitor` để Prometheus scrape:

```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: goshop
spec:
  selector: { matchLabels: { app.kubernetes.io/name: goshop } }
  endpoints:
    - port: http
      path: /metrics
```

### Alert ví dụ

Trong `PrometheusRule`:
- Pod CrashLoop > 5 phút
- HTTP 5xx > 5% trong 10 phút
- Postgres connections > 80% max
- PVC dung lượng > 80%

---

## 9.7 Restore drill

> "Backup chưa restore được = chưa có backup."

Quy trình tháng/quý:
1. Tạo cluster phụ (hoặc namespace `data-restore`) trên cùng k3s
2. Tải file dump mới nhất từ S3
3. `kubectl run psql --rm -it ... -- psql ... < dump.sql`
4. Verify: row count, timestamp record mới nhất
5. Document RTO thực tế trong runbook

---

## Kết thúc roadmap

Đến đây bạn có:
- Cluster k3s vận hành ổn định, có observability
- App goshop deploy tự động từ git, có CI/CD
- Secrets ngoài git (Doppler)
- Backup + restore tested
- Multi-replica, HPA, PDB

Bước tiếp **không có trong roadmap**:
- Multi-cluster (vd add staging k3s riêng → ArgoCD quản cả 2)
- Service mesh (Istio/Linkerd) nếu cần mTLS pod-to-pod
- Container scanning (Trivy/Grype) trong CI
- Policy as code (OPA Gatekeeper, Kyverno)
- DR + multi-region

→ Khi cần, tạo phase 10+ với cùng pattern README + script + verify.
