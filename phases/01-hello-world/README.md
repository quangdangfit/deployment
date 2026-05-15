# Phase 1 — Hello-world trên k8s

## Mục tiêu

Deploy 1 pod nginx, truy cập được từ trình duyệt qua `http://<VM_IP>:30080`. Mục đích **không phải nginx** — mà là làm quen 4 primitive cốt lõi của Kubernetes:

1. **Namespace** — vùng logic ngăn cách resource
2. **Deployment** — quản lý lifecycle của replica pod
3. **Service** — endpoint ổn định để truy cập pod
4. **NodePort** — cách expose service ra ngoài cluster (đơn giản nhất, không cần ingress)

Đồng thời học các lệnh debug: `kubectl get/describe/logs/exec/port-forward`.

**Đầu ra mong đợi:**
```bash
$ curl http://$VM_IP:30080
<!DOCTYPE html><html>...<h1>Welcome to nginx!</h1>...
```

## Kiến thức nền

### Hierarchy resource trong k8s

```
Cluster
└── Namespace (logical isolation, RBAC boundary)
    ├── Deployment ──manages──> ReplicaSet ──creates──> Pod (1..N)
    │                                                    │
    │                                                    └── Container(s)
    └── Service ──routes traffic to──> Pod (qua label selector)
```

**Pod:** đơn vị nhỏ nhất, chứa 1+ container chia chung network/storage. Pod **ephemeral** — chết là mất IP, có thể tái sinh chỗ khác.

**Deployment:** declarative spec "tôi muốn 2 replica của image X". Controller liên tục so sánh state thực vs spec, tự tạo/xoá Pod.

**Service:** vì pod IP thay đổi, mình cần endpoint ổn định. Service có 4 kiểu:

| Type | Dùng khi |
|---|---|
| `ClusterIP` (mặc định) | Pod-to-pod nội bộ, chỉ truy cập được trong cluster |
| `NodePort` | Mở 1 port (30000-32767) trên **mọi node** → traffic vào port đó → routing đến pod |
| `LoadBalancer` | Tạo external LB (chỉ hoạt động ở cloud có LB controller) |
| `ExternalName` | DNS alias đến hostname ngoài cluster |

Phase này dùng `NodePort` vì đơn giản nhất, không cần thêm component nào.

### Label selector

Service tìm pod để route bằng cách **so khớp label**, không phải bằng tên:

```yaml
# Deployment đặt label cho pod:
spec:
  template:
    metadata:
      labels:
        app: hello-nginx
---
# Service chọn pod bằng selector:
spec:
  selector:
    app: hello-nginx
```

→ Nếu label không khớp, service "rỗng" — traffic không đi đâu cả. Lỗi rất phổ biến với người mới.

### Tại sao tách namespace?

Đặt `hello-world` trong namespace riêng (không phải `default`) để:
- Dễ teardown: `kubectl delete ns hello-world` xoá sạch trong 1 lệnh
- Tập làm quen với khái niệm `-n <namespace>`
- Tránh lẫn với phase sau

## Các bước

### Step 1 — Đảm bảo `KUBECONFIG` được set

```bash
export KUBECONFIG=$HOME/.kube/k3s-goshop.yaml
kubectl get nodes   # phải thấy 1 node Ready
```

### Step 2 — Đọc qua các manifest

3 file YAML trong `manifests/`:
- `00-namespace.yaml` — tạo namespace `hello-world`
- `10-deployment.yaml` — 2 replica nginx
- `20-service.yaml` — NodePort 30080

Tên file đánh số để kubectl apply theo thứ tự alphabet → namespace tạo trước → deployment/service đặt vào đúng ns.

> Bạn có thể đọc kỹ từng file trước khi apply để hiểu cấu trúc YAML.

### Step 3 — Apply

```bash
./apply.sh
```

Hoặc thủ công:
```bash
kubectl apply -f manifests/
```

`apply` là **declarative** — k8s so sánh state hiện tại với file và áp dụng chênh lệch. Chạy lại nhiều lần không hại.

### Step 4 — Khám phá

```bash
# Liệt kê resource
kubectl -n hello-world get all
kubectl -n hello-world get pods -o wide   # xem pod chạy ở node nào, IP gì

# Xem chi tiết (event, container spec, status):
kubectl -n hello-world describe deployment hello-nginx
kubectl -n hello-world describe pod <tên-pod>

# Xem log của 1 pod:
kubectl -n hello-world logs <tên-pod>
kubectl -n hello-world logs -l app=hello-nginx --tail=20   # log từ tất cả pod match label

# Vào shell trong container:
kubectl -n hello-world exec -it <tên-pod> -- sh
# Trong shell, thử:  curl localhost; cat /etc/nginx/nginx.conf

# Port-forward (không cần NodePort, chỉ test local):
kubectl -n hello-world port-forward svc/hello-nginx 8080:80
# Mở tab khác:  curl localhost:8080
```

→ Học **bằng cách gõ tay** từng lệnh này. Đây là toolkit hằng ngày khi vận hành k8s.

### Step 5 — Truy cập từ ngoài

NodePort 30080 đã mở. Test:

```bash
curl http://$VM_IP:30080
```

Hoặc mở browser `http://<VM_IP>:30080`.

> Nếu **timeout**: kiểm tra OCI Security List có rule cho port 30080 chưa. NodePort range là 30000-32767. Bạn có thể mở rule riêng `30080/TCP` hoặc cả range cho dễ test sau.

### Step 6 — Hiểu cơ chế self-healing

```bash
# Xoá 1 pod, xem Deployment tự tái sinh:
kubectl -n hello-world delete pod <tên-pod>
kubectl -n hello-world get pods -w   # watch — pod mới sẽ xuất hiện trong 5-10s
```

Nhấn `Ctrl+C` để thoát watch.

## Verify

```bash
./verify.sh
```

Script này check:
- Namespace tồn tại
- Deployment có 2/2 replica Ready
- Service có endpoint
- HTTP 200 khi curl `$VM_IP:30080`

## Troubleshooting

| Triệu chứng | Lệnh chẩn đoán | Nguyên nhân thường gặp |
|---|---|---|
| Pod `Pending` mãi | `kubectl -n hello-world describe pod ...` (xem Events) | Node thiếu resource, hoặc PVC chờ — phase này không có PVC nên hiếm |
| Pod `CrashLoopBackOff` | `kubectl logs ...` | App crash khi start. Đọc log là ra |
| Pod `ImagePullBackOff` | `describe pod` | Image không tồn tại, registry private, hoặc network ra ngoài bị chặn |
| Service không có endpoint | `kubectl -n hello-world get endpoints hello-nginx` | Selector label không khớp với label pod |
| `curl $VM_IP:30080` timeout | (1) `nc -vz $VM_IP 30080` (2) check OCI Security List | Port chưa mở ở cloud firewall |
| Conflict với ingress sau này | n/a | NodePort range không xung đột với 80/443 |

## Cleanup

```bash
./teardown.sh
# hoặc:
kubectl delete ns hello-world
```

Xoá ns sẽ xoá mọi thứ bên trong (cascading delete). Pod thoát trong ~10s.

---

→ **Next:** [Phase 2 — Postgres + Redis raw](../02-data/)
