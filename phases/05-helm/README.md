# Phase 5 — Helm chart cho goshop

## Mục tiêu

Đóng gói raw manifests của goshop (Phase 3) + Ingress (Phase 4) thành **Helm chart** riêng. Sau phase này:
- 1 lệnh `helm upgrade --install` thay cho `kubectl apply -f ...` lẻ tẻ
- Tách config theo môi trường (`values-dev.yaml`, `values-prod.yaml`)
- Tag image, replicas, resources, ingress host đều parametrize qua values

**Đầu ra mong đợi:**
```bash
$ helm -n goshop list
NAME    NAMESPACE  CHART          STATUS
goshop  goshop     goshop-0.1.0   deployed
```

App vẫn truy cập được qua `https://goshop.cunghoclaptrinh.online` (chart sinh ra ingress y hệt Phase 4).

## Kiến thức nền

### Chart structure

```
chart/goshop/
├── Chart.yaml             # name, version (chart version) + appVersion
├── values.yaml            # default values (override được)
├── values-prod.yaml       # overlay cho prod (chỉ ghi đè key cần đổi)
├── templates/
│   ├── _helpers.tpl       # template snippets dùng lại (vd: full name, labels chuẩn)
│   ├── configmap.yaml
│   ├── deployment.yaml
│   ├── service.yaml
│   └── ingress.yaml
└── .helmignore
```

### Template syntax — Go template

```yaml
metadata:
  name: {{ include "goshop.fullname" . }}      # gọi template từ _helpers.tpl
  labels:
    app: {{ .Values.app.name }}                  # access values.yaml
spec:
  replicas: {{ .Values.replicaCount }}
  {{- if .Values.ingress.enabled }}              # conditional
  ingress: enabled
  {{- end }}
  image: "{{ .Values.image.repository }}:{{ .Values.image.tag | default .Chart.AppVersion }}"
```

- `{{ ... }}` — code
- `{{- ... -}}` — trim whitespace 2 đầu
- `.Values` — values.yaml/overrides
- `.Chart` — Chart.yaml
- `.Release` — runtime info (release name, namespace, …)
- `include "..."` — gọi named template
- `| default X` — fallback nếu giá trị empty

### Tại sao tách `values-prod.yaml`?

Common pattern: 1 base `values.yaml` cho default (= dev), 1 file overlay cho từng môi trường ghi đè chỉ key cần đổi:

```bash
helm upgrade --install goshop ./chart \
  -f chart/values.yaml \
  -f chart/values-prod.yaml      # ghi đè key trùng
```

→ DRY, dễ diff giữa môi trường.

### `helm template` vs `helm install`

- `helm template` — render YAML ra stdout, KHÔNG apply. Dùng để **debug** xem template render đúng không.
- `helm install/upgrade` — render + apply.

Best practice: luôn `helm template ... > /tmp/rendered.yaml` xem trước khi apply nếu chart phức tạp.

### Helm 3 release tracking

Helm 3 không cần Tiller. State của release lưu trong Secret `sh.helm.release.v1.<release>.<rev>` ở namespace target. `helm uninstall` xóa secret + resources.

## Layout file

```
phases/05-helm/
├── README.md
├── chart/goshop/
│   ├── Chart.yaml
│   ├── values.yaml             # default = dev profile (staging issuer)
│   ├── values-prod.yaml        # overlay: prod issuer, replicas=2, image tag thật
│   ├── .helmignore
│   └── templates/
│       ├── _helpers.tpl
│       ├── configmap.yaml
│       ├── deployment.yaml
│       ├── service.yaml
│       └── ingress.yaml
├── install.sh
├── uninstall.sh
└── verify.sh
```

## Các bước

### Step 1 — Tear down raw resources từ Phase 3 (giữ Phase 4 platform)

```bash
kubectl -n goshop delete deployment,service,configmap,ingress -l app=goshop --ignore-not-found
# Hoặc đơn giản: kubectl delete ns goshop (sẽ tạo lại bằng helm)
```

Giữ `ingress-nginx`, `cert-manager`, ClusterIssuer.

### Step 2 — Đọc qua chart

Mở `chart/goshop/values.yaml` xem các key có thể tweak: image tag, replicas, ingress host, config DSN, ...

```bash
# Render xem ra YAML gì:
helm template goshop ./chart/goshop -n goshop \
  --set image.repository=ghcr.io/$GHCR_USER/goshop \
  --set image.tag=phase5
```

### Step 3 — Install dev profile

```bash
export GHCR_USER=quangdangfit
export IMAGE_TAG=phase5
./install.sh dev
```

Script chạy:
```bash
helm upgrade --install goshop ./chart/goshop \
  --namespace goshop --create-namespace \
  --set image.repository=ghcr.io/$GHCR_USER/goshop \
  --set image.tag=$IMAGE_TAG \
  --wait
```

Xem release:
```bash
helm -n goshop list
helm -n goshop status goshop
helm -n goshop get values goshop      # values đã apply
helm -n goshop get manifest goshop    # YAML đã render
```

### Step 4 — Build image mới với tag phase5

```bash
GHCR_USER=quangdangfit GHCR_TOKEN=... TAG=phase5 \
  ../03-goshop/build-and-push.sh
```

Hoặc reuse `phase3` tag — không bắt buộc đổi.

### Step 5 — Upgrade với prod profile

Khi sẵn sàng (cert prod đã setup ở Phase 4):
```bash
./install.sh prod
```

Script truyền thêm `-f chart/goshop/values-prod.yaml` để override:
- `ingress.clusterIssuer: letsencrypt-prod`
- `replicaCount: 2`
- (tùy bạn thêm)

### Step 6 — Rollback (nếu cần)

```bash
helm -n goshop history goshop
helm -n goshop rollback goshop 1     # về revision 1
```

## Verify

```bash
./verify.sh
```

## Troubleshooting

| Triệu chứng | Lệnh | Fix |
|---|---|---|
| `Error: template ... failed` | `helm template ... --debug` | Lỗi syntax trong template |
| `values doesn't validate` | n/a | Sai key trong values.yaml — check `helm lint chart/goshop` |
| Release stuck `pending-upgrade` | `helm -n goshop history goshop` | `helm -n goshop rollback goshop <last-good>` |
| `ImagePullBackOff` sau upgrade | `kubectl describe pod` | Image tag không tồn tại trên registry |

## Cleanup

```bash
./uninstall.sh
# = helm -n goshop uninstall goshop
```

KHÔNG xóa ns `data` (Phase 2) hay platform charts.

---

→ **Next:** [Phase 6 — GitOps với ArgoCD](../06-argocd/)
