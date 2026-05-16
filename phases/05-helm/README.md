# Phase 5 — Helm chart cho goshop

## Mục tiêu

Đóng gói raw manifests của goshop (Phase 3) + Ingress (Phase 4) thành **Helm chart** riêng. Sau phase này:
- 1 lệnh `helm upgrade --install` thay cho `kubectl apply -f ...` lẻ tẻ
- Tag image, replicas, resources, ingress host đều parametrize qua `values.yaml`

**Đầu ra mong đợi:**
```bash
$ helm -n default list
NAME    NAMESPACE  CHART          STATUS
goshop  goshop     goshop-0.1.0   deployed
```

App vẫn truy cập được qua `https://goshop.cunghoclaptrinh.online` (chart sinh ra ingress y hệt Phase 4).

## Kiến thức nền

### Helm là gì?

**Helm** là **package manager cho Kubernetes** — như `apt` cho Ubuntu, `npm` cho Node, `brew` cho macOS, nhưng cho k8s.

Đơn vị package gọi là **chart** — một thư mục chứa **template YAML** + **file values mặc định**. Khi cài, helm render template với values rồi đẩy ra `kubectl apply` thay cho bạn.

```
[chart/]  ──helm install──>  [rendered YAML]  ──kubectl apply──>  [k8s resources]
   ▲                              ▲
   │                              │ values.yaml ghi đè
   │
   templates/*.yaml chứa {{ .Values.xxx }}
```

### Vấn đề Helm giải quyết

Không có Helm, deploy 1 app vừa = vừa nghĩa đầy đủ trên k8s cần **5-15 file YAML** (ns, deployment, service, ingress, configmap, secret, hpa, pdb, networkpolicy, …). Vấn đề phát sinh:

| Vấn đề | Không Helm | Có Helm |
|---|---|---|
| **Param hoá config** | Hardcode trong YAML, sửa tay mỗi lần | Tách `values.yaml`, override bằng `--set` hoặc `-f` |
| **Param hoá runtime** | sed/envsubst/yq hack | `{{ .Values.replicaCount }}` native |
| **Track app version** | git tag tay | Chart.yaml: `version` (chart) + `appVersion` (app), revision tự đếm |
| **Rollback** | kubectl rollout undo từng deployment lẻ tẻ | `helm rollback <release> <revision>` — 1 lệnh revert hết |
| **Uninstall sạch** | nhớ xóa tất cả resource bằng tay | `helm uninstall` — xóa hết resource thuộc release |
| **Dependency** | Tự apply postgres trước app | `dependencies:` trong Chart.yaml, helm pull + install theo thứ tự |
| **Cài chart bên thứ 3** | Tìm/copy YAML, sửa, apply | `helm install ingress-nginx ingress-nginx/ingress-nginx` — Phase 4 đã làm |
| **Share giữa team** | Truyền file qua chat | Helm repo (artifacthub, OCI registry) — pull bằng URL |

### Khái niệm cốt lõi

- **Chart** — thư mục `chart/<name>/` chứa Chart.yaml + templates + values
- **Release** — 1 instance chart đã cài (`helm install <release-name> <chart>`). Cùng chart có thể cài nhiều release với release name khác nhau.
- **Revision** — mỗi lần `helm upgrade` tăng 1; rollback theo số revision
- **Repository** — server lưu nhiều chart (https://kubernetes.github.io/ingress-nginx, https://charts.jetstack.io, …)

### Khi nào KHÔNG cần Helm

- Cluster cá nhân, 1-2 resource đơn giản — `kubectl apply -f` đủ
- Manifest cực ngắn và không cần param hoá
- Bạn dùng Kustomize (overlay-based, không template) thay vì Helm

→ Goshop có ~7 manifest cần param hoá tag/replicas/host → Helm thắng rõ rệt.

### Helm 3 vs Helm 2

Helm 2 có server-side component `Tiller` (cài trong cluster, mang cluster-admin) — bị rủi ro bảo mật. **Helm 3 (current)**: client-only, state lưu trong Secret ở chính ns của release, không cần Tiller. Tài liệu cũ đề cập Tiller = lỗi thời.

### Chart structure

```
chart/goshop/
├── Chart.yaml             # name, version (chart version) + appVersion
├── values.yaml            # values (override được qua --set)
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
│   ├── values.yaml             # prod values (issuer=letsencrypt-prod, replicas=2)
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
kubectl -n default delete deployment,service,configmap,ingress -l app=goshop --ignore-not-found
# Hoặc đơn giản: kubectl delete ns goshop (sẽ tạo lại bằng helm)
```

Giữ `ingress-nginx`, `cert-manager`, ClusterIssuer.

### Step 2 — Đọc qua chart

Mở `chart/goshop/values.yaml` xem các key có thể tweak: image tag, replicas, ingress host, config DSN, ...

```bash
# Render xem ra YAML gì:
helm template goshop ./chart/goshop -n goshop \
  --set image.repository=ghcr.io/$GHCR_USER/goshop \
  --set image.tag=master
```

### Step 3 — Install

```bash
export GHCR_USER=quangdangfit
export IMAGE_TAG=master
./install.sh
```

Script chạy:
```bash
helm upgrade --install goshop ./chart/goshop \
  --namespace default --create-namespace \
  --set image.repository=ghcr.io/$GHCR_USER/goshop \
  --set image.tag=$IMAGE_TAG \
  --wait
```

Xem release:
```bash
helm -n default list
helm -n default status goshop
helm -n default get values goshop      # values đã apply
helm -n default get manifest goshop    # YAML đã render
```

### Step 4 — Build image mới với tag master

```bash
GHCR_USER=quangdangfit GHCR_TOKEN=... TAG=master \
  ../03-goshop/build-and-push.sh
```

Hoặc reuse tag đã có từ Phase 3 — không bắt buộc đổi.

### Step 5 — Rollback (nếu cần)

```bash
helm -n default history goshop
helm -n default rollback goshop 1     # về revision 1
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
| Release stuck `pending-upgrade` | `helm -n default history goshop` | `helm -n default rollback goshop <last-good>` |
| `ImagePullBackOff` sau upgrade | `kubectl describe pod` | Image tag không tồn tại trên registry |

## Cleanup

```bash
./uninstall.sh
# = helm -n default uninstall goshop
```

KHÔNG xóa ns `data` (Phase 2) hay platform charts.

---

→ **Next:** [Phase 6 — GitOps với ArgoCD](../06-argocd/)
