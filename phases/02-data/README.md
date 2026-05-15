# Phase 2 — Postgres + Redis (raw manifests)

## Mục tiêu

Chạy Postgres và Redis trên k8s **không dùng Helm**, để bạn hiểu rõ từng resource. Sau phase này:
- Postgres 16 chạy với data lưu trên disk VM, không mất khi restart pod
- Redis 7 chạy in-memory (cache, không cần persistence)
- Cả 2 có Service nội bộ để goshop ở Phase 3 kết nối được

**Đầu ra mong đợi:**
```bash
$ kubectl -n data get pods
NAME           READY   STATUS    RESTARTS   AGE
postgres-0     1/1     Running   0          1m
redis-...      1/1     Running   0          1m
```

## Kiến thức nền

### Deployment vs StatefulSet

| | Deployment | StatefulSet |
|---|---|---|
| Pod name | random (`nginx-7f4b-xyz`) | đánh số (`postgres-0`, `postgres-1`) |
| DNS | random per replica | ổn định (`postgres-0.postgres.data.svc.cluster.local`) |
| Storage | shared hoặc emptyDir | mỗi pod có PVC riêng (template) |
| Khi scale | tạo/xoá random | tạo/xoá theo thứ tự, có guarantee |
| Dùng cho | stateless app (web, api) | database, broker, anything cần identity |

→ **Postgres = StatefulSet** vì cần persistent volume riêng + tên pod ổn định.
→ **Redis** ở phase này **= Deployment** vì mình dùng nó làm cache (mất là tạo lại không sao). Production-grade Redis cluster sẽ là StatefulSet, nhưng để đơn giản giờ chưa cần.

### PersistentVolume (PV) và PersistentVolumeClaim (PVC)

```
Pod ──claims──> PVC ──bound to──> PV ──backed by──> [thực: disk trên node]
```

- **PV:** đại diện 1 ổ đĩa thật (storage class quyết định kiểu — local disk, NFS, AWS EBS, …)
- **PVC:** "yêu cầu" của pod: "tôi cần 10GB, mode ReadWriteOnce"
- **StorageClass:** template để **tự động tạo PV** khi có PVC mới (dynamic provisioning)

K3s tự cài sẵn StorageClass `local-path` — PVC tự được cấp 1 thư mục trên node tại `/var/lib/rancher/k3s/storage/...`. Đơn giản, đủ cho single-node, **không hỗ trợ migration sang node khác** (nhưng cluster mình chỉ có 1 node).

### Headless Service (clusterIP: None)

```yaml
spec:
  clusterIP: None
```

→ DNS sẽ trả về **IP của từng pod**, không phải 1 VIP. Cần cho StatefulSet để mỗi pod có DNS riêng (`postgres-0.postgres`).

### Secret

`Secret` lưu chuỗi đã base64. Cách viết tay tiện nhất là `stringData`:

```yaml
stringData:
  password: goshop_dev   # k8s tự base64
```

→ Phase này hardcode mật khẩu vào file YAML. Phase 7 sẽ chuyển sang External Secrets + Doppler để **không** commit mật khẩu vào git.

## Layout file

```
phases/02-data/
├── manifests/
│   ├── 00-namespace.yaml
│   ├── 10-secret.yaml           # mật khẩu DB + Redis (hardcoded, sẽ refactor ở Phase 7)
│   ├── 20-postgres-svc.yaml     # headless Service
│   ├── 21-postgres-sts.yaml     # StatefulSet với PVC template
│   ├── 30-redis-svc.yaml
│   └── 31-redis-deploy.yaml
├── apply.sh
├── verify.sh
└── teardown.sh
```

## Các bước

### Step 1 — Apply

```bash
./apply.sh
```

Script đợi cả 2 pod Ready. Lần đầu mất ~1-2 phút (pull image, init data dir).

### Step 2 — Khám phá

```bash
# Pod, PVC, Service:
kubectl -n data get pods,pvc,svc

# Xem PVC bound vào PV nào:
kubectl -n data describe pvc data-postgres-0

# Xem data thực ở đâu trên VM:
kubectl -n data get pv $(kubectl -n data get pvc data-postgres-0 -o jsonpath='{.spec.volumeName}') -o jsonpath='{.spec.local.path}{"\n"}'

# Xem log Postgres khởi tạo:
kubectl -n data logs postgres-0
```

### Step 3 — Test kết nối từ pod tạm

```bash
# Postgres: tạo bảng tạm, insert, query
kubectl -n data run psql-test --rm -it --restart=Never --image=postgres:16-alpine -- \
  psql 'postgres://goshop:goshop_dev@postgres:5432/goshop' \
  -c 'CREATE TABLE IF NOT EXISTS hello (id serial, msg text);' \
  -c "INSERT INTO hello (msg) VALUES ('phase 2 works');" \
  -c 'SELECT * FROM hello;'

# Redis: PING
kubectl -n data run redis-test --rm -it --restart=Never --image=redis:7-alpine -- \
  redis-cli -h redis -a redis_dev PING
```

### Step 4 — Test persistence (quan trọng!)

```bash
# Xoá pod postgres — StatefulSet sẽ tạo lại với CÙNG PVC
kubectl -n data delete pod postgres-0
kubectl -n data get pods -w   # đợi Running, Ctrl+C

# Verify data vẫn còn:
kubectl -n data run psql-test --rm -it --restart=Never --image=postgres:16-alpine -- \
  psql 'postgres://goshop:goshop_dev@postgres:5432/goshop' \
  -c 'SELECT * FROM hello;'
# Phải thấy lại dòng "phase 2 works"
```

→ Đây là khác biệt cốt lõi với hello-world: pod chết nhưng **data ở lại** vì PVC độc lập với pod lifecycle.

## Verify

```bash
./verify.sh
```

## Troubleshooting

| Triệu chứng | Lệnh | Fix |
|---|---|---|
| `postgres-0` Pending mãi | `kubectl -n data describe pod postgres-0` | Xem Events. `FailedScheduling` thường do PVC. Check `kubectl -n data get pvc` |
| PVC Pending | `kubectl -n data describe pvc data-postgres-0` | StorageClass `local-path` không tồn tại → `kubectl get sc` |
| `CrashLoopBackOff` Postgres | `kubectl -n data logs postgres-0` | Permission `/var/lib/postgresql/data` — đã set `fsGroup: 999` trong securityContext |
| Redis auth fail | `kubectl -n data logs deploy/redis` | Sai password trong Secret hoặc args `--requirepass` |

## Cleanup

```bash
./teardown.sh
```

> Xoá ns sẽ xoá pod + PVC + PV → **data mất hoàn toàn**.

---

→ **Next:** [Phase 3 — Build & deploy goshop](../03-goshop/)
