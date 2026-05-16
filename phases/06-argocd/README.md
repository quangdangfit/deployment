# Phase 6 — GitOps với ArgoCD

## Mục tiêu

Thay `helm upgrade --install` thủ công bằng **GitOps**: viết chart vào git, ArgoCD tự đọc + apply. Push commit → app deploy tự động.

Sau phase này:
- ArgoCD chạy tại `https://argocd.cunghoclaptrinh.online`
- 1 ArgoCD `Application` đại diện cho chart goshop, auto-sync từ git
- Mỗi `git push` vào branch sẽ tự reflect lên cluster trong < 3 phút

**Đầu ra mong đợi:**
```bash
$ kubectl -n argocd get applications
NAME    SYNC STATUS   HEALTH STATUS
goshop  Synced        Healthy
```

## Kiến thức nền

### GitOps — git là single source of truth

```
Developer ──push──> Git repo ──watched by──> ArgoCD ──applies──> k8s cluster
                                                ↑
                                       cluster state should match git
```

Lợi ích:
- **Audit:** mọi thay đổi đều qua commit, có blame + diff
- **Rollback:** `git revert` = revert deploy
- **Disaster recovery:** clone repo + apply root = rebuild cluster
- **Multi-env:** branch hoặc folder cho từng môi trường

So với "kubectl apply tay" hoặc "CI/CD push":
- **Pull-based** (ArgoCD pull từ git) thay vì push-based (CI push lên cluster) → cluster credentials không lộ ra CI
- ArgoCD **liên tục so sánh** state thực vs git → drift detect tự động

### ArgoCD components

| Component | Vai trò |
|---|---|
| `argocd-server` | UI/API |
| `argocd-repo-server` | Clone git, render chart/kustomize |
| `argocd-application-controller` | Reconcile loop: so sánh git vs cluster, sync nếu cần |
| `argocd-applicationset-controller` | Sinh nhiều Application từ 1 ApplicationSet (advanced) |
| `argocd-redis` | Cache |
| `argocd-dex` | OIDC (mình tắt, không cần SSO ở phase này) |

### Application = 1 unit deploy

```yaml
kind: Application
spec:
  source:
    repoURL: https://github.com/quangdangfit/deployment
    path: phases/05-helm/chart/goshop
    targetRevision: main
    helm:
      valueFiles: [values.yaml]
  destination:
    server: https://kubernetes.default.svc
    namespace: default
  syncPolicy:
    automated:
      prune: true       # xóa resource khi xóa trong git
      selfHeal: true    # tự sync khi cluster drift
```

### AppProject = boundary

Project nhóm các Application + giới hạn cái gì được phép sync:
- `sourceRepos`: chỉ repo nào được phép
- `destinations`: chỉ ns nào được phép
- `clusterResourceWhitelist`: chỉ kind nào được phép

Phase này dùng project `default` cho đơn giản. Production-grade: tạo project riêng `goshop` để cô lập RBAC.

### App-of-Apps pattern

```
root Application ───manages───> Application(goshop)
                            └──> Application(postgres)
                            └──> Application(redis)
                            └──> Application(monitoring)
```

→ Một `Application` cha apply YAML của nhiều Application con. Cluster chỉ cần `kubectl apply -f root.yaml` 1 lần, mọi thứ về sau quản qua git.

Phase này chưa cần. Phase 9 (hardening) khi có nhiều app sẽ dùng pattern này.

### Image tag chiến lược

| Tag | Ưu | Nhược |
|---|---|---|
| `latest` / `master` | đơn giản, luôn mới | KHÔNG immutable → ArgoCD không phát hiện đổi (cluster đã pull rồi) → cần Image Updater |
| `<sha>` hoặc `<semver>` | immutable, ArgoCD detect khi values.yaml đổi | phải bump bằng tay hoặc CI |

Phase 6 dùng tag cố định (`master`). Phase 8 add ArgoCD Image Updater để tự bump tag khi có image mới.

## Layout file

```
phases/06-argocd/
├── README.md
├── install-argocd.sh           # helm cài argocd
├── manifests/
│   ├── argocd-ingress.yaml     # expose UI qua https://argocd.domain
│   └── goshop-app.yaml         # Application chỉ vào phases/05-helm/chart/goshop
├── apply-app.sh
├── verify.sh
└── teardown.sh
```

## Các bước

### Step 1 — Cài ArgoCD

```bash
./install-argocd.sh
```

Script:
1. helm repo add argo
2. helm install argocd ở ns `argocd` với:
   - `dex.enabled=false` (không cần OIDC)
   - `notifications.enabled=false` (chưa cần Slack)
   - `configs.params.server.insecure=true` (TLS terminate ở ingress)
   - Resource requests modest cho 16GB VM

### Step 2 — Trỏ DNS Cloudflare

Thêm A record `argocd → $VM_IP`, proxy OFF.

### Step 3 — Expose ArgoCD UI

```bash
kubectl apply -f manifests/argocd-ingress.yaml
kubectl -n argocd wait --for=condition=Ready certificate/argocd-tls --timeout=180s
```

Mở browser: `https://argocd.cunghoclaptrinh.online`

**Login:**
- Username: `admin`
- Password:
  ```bash
  kubectl -n argocd get secret argocd-initial-admin-secret \
    -o jsonpath='{.data.password}' | base64 -d; echo
  ```

→ Đổi password ngay sau lần login đầu:
```bash
argocd login argocd.cunghoclaptrinh.online --username admin --password '<initial>'
argocd account update-password
# sau đó:
kubectl -n argocd delete secret argocd-initial-admin-secret
```

### Step 4 — Đảm bảo repo deployment public (hoặc add credential)

Cách đơn giản: repo `deployment` public → ArgoCD đọc không cần auth.

Nếu private: thêm credential trong ArgoCD:
- UI → Settings → Repositories → Connect repo
- Hoặc kubectl apply Secret kiểu `argocd.argoproj.io/secret-type: repository`

### Step 5 — Tear down helm release từ Phase 5

ArgoCD sẽ "adopt" chart, nhưng để tránh conflict ownership:
```bash
helm -n default uninstall goshop || true
# Đừng xóa ns goshop, ArgoCD sẽ tái sinh resource bên trong
```

### Step 6 — Tạo Application

```bash
./apply-app.sh
```

Script apply `manifests/goshop-app.yaml` chỉ vào `phases/05-helm/chart/goshop` ở revision `main`.

Theo dõi trong UI hoặc CLI:
```bash
kubectl -n argocd get applications -w
# Đợi: SYNC=Synced, HEALTH=Healthy
```

Lần đầu ArgoCD sẽ:
1. Clone repo (~5s)
2. Render chart với values.yaml (mặc định dev)
3. Apply lên ns `goshop`
4. Mark Synced + Healthy

### Step 7 — Test GitOps flow

Edit `phases/05-helm/chart/goshop/values.yaml` → đổi `replicaCount: 2` → commit + push.

```bash
git add phases/05-helm/chart/goshop/values.yaml
git commit -m "test: scale goshop to 2 replicas"
git push origin main
```

Quan sát ArgoCD UI: trong vòng ~3 phút (poll interval mặc định) sẽ tự sync. Hoặc force:
```bash
kubectl -n argocd patch app goshop --type merge -p '{"operation":{"sync":{}}}'
```

Verify:
```bash
kubectl -n default get pods   # phải thấy 2 pod
```

## Verify

```bash
./verify.sh
```

## Troubleshooting

| Triệu chứng | Lệnh | Fix |
|---|---|---|
| App `OutOfSync` mãi | `kubectl -n argocd describe app goshop` (Events) | Có thể chart render lỗi — `helm template` thử local |
| App `Degraded` | UI → app → tab Resources xem cái nào unhealthy | Thường pod chưa Ready, hoặc cert chưa cấp |
| Repo connect fail | UI → Settings → Repositories | Repo private + chưa add credential |
| Sync mãi không chạy auto | `helm template ... --debug` | Có thể auto-sync chưa bật trong Application |
| `another operation is already in progress` | n/a | Patch xóa lock: `kubectl -n argocd patch app goshop --type merge -p '{"operation":null}'` |

## Cleanup

```bash
./teardown.sh
```

Xóa Application + Ingress argocd. KHÔNG uninstall argocd chart (Phase 7+ vẫn dùng).

---

→ **Next:** [Phase 7 — Doppler + External Secrets](../07-doppler-eso/)
