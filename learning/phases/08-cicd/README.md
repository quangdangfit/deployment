# Phase 8 — CI/CD: build image + auto rollout

## Mục tiêu

Tự động hoá pipeline: **push code goshop → image mới trên ghcr → ArgoCD tự bump tag trong git → deploy**.

Sau phase này, bạn không bao giờ phải:
- Build image local (`docker buildx ...`)
- Sửa `values.yaml` đổi tag bằng tay
- Chạy `kubectl apply` thủ công

```
goshop repo (push master)
       │
       ▼
GitHub Actions: buildx multi-arch → push ghcr.io/.../goshop:<sha>
       │
       ▼
ArgoCD Image Updater (poll mỗi 2 phút): phát hiện tag mới
       │
       ▼ commits update to deployment repo
deployment repo (values.yaml: image.tag: <new-sha>)
       │
       ▼
ArgoCD reconcile: sync goshop Application → rolling deploy
```

## Kiến thức nền

### Tag strategy cho immutable rollout

| Tag | Có dùng được không | Lý do |
|---|---|---|
| `latest` | ❌ | Không immutable, k3s đã cache layer, không pull lại |
| `master` | ❌ | Như trên |
| `<short-sha>` (vd `a1b2c3d`) | ✅ | Immutable, k8s detect thay đổi khi tag string khác |
| `v1.2.3` (semver) | ✅ | Cho release chính thức, kèm tag git |

Phase 3-7 dùng tag `master` cố định (chỉ học). Phase 8 dùng **`master-<sha>`** — tự sinh bởi GitHub Action.

### GitHub Actions cơ bản

```yaml
name: ...
on:
  push:
    branches: [master]    # trigger
jobs:
  build:
    runs-on: ubuntu-latest
    permissions:
      packages: write     # cần để push ghcr.io
    steps:
      - uses: actions/checkout@v4
      - uses: docker/setup-qemu-action@v3     # cài QEMU cho cross-arch build
      - uses: docker/setup-buildx-action@v3   # bật buildx
      - uses: docker/login-action@v3          # auth ghcr.io
      - uses: docker/build-push-action@v6     # build + push
```

### `GITHUB_TOKEN` vs Personal Access Token (PAT)

- `GITHUB_TOKEN`: secret tự động trong mỗi workflow, scope giới hạn trong repo. **Đủ** để push image lên ghcr.io thuộc cùng owner.
- PAT: token cá nhân, scope rộng hơn. Cần khi workflow phải **commit lên repo khác** (vd image-updater commit lên `deployment` repo từ goshop repo). Hoặc dùng GitHub App.

### ArgoCD Image Updater (AIU)

Component bên cạnh ArgoCD, làm 2 việc:
1. **Poll** image registry mỗi N phút, tìm tag mới phù hợp pattern (vd `^master-[0-9a-f]+$`)
2. Khi có tag mới → **commit** vào git repo (đường dẫn `.image.tag` trong values.yaml) → ArgoCD reconcile trigger rollout

Cấu hình qua **annotation** trên ArgoCD `Application`:
```yaml
metadata:
  annotations:
    argocd-image-updater.argoproj.io/image-list: goshop=ghcr.io/quangdangfit/goshop
    argocd-image-updater.argoproj.io/goshop.update-strategy: newest-build
    argocd-image-updater.argoproj.io/goshop.allow-tags: regexp:^master-[0-9a-f]{7}$
    argocd-image-updater.argoproj.io/write-back-method: git
    argocd-image-updater.argoproj.io/write-back-target: helmvalues:./values.yaml
```

### Image Updater cần quyền ghi repo

Workflow:
- Tạo PAT có scope `repo` (write)
- Tạo Secret ở ns `argocd` chứa key
- Reference từ Application annotation `git-repository=<creds-secret>`

## Layout file

```
phases/08-cicd/
├── README.md
├── goshop-workflow.yml          # file COPY vào goshop repo: .github/workflows/docker.yml
├── install-image-updater.sh
├── manifests/
│   ├── git-creds-secret.yaml.tpl    # template Secret chứa PAT cho AIU write-back
│   └── goshop-app-updated.yaml      # Application với annotation AIU
├── apply.sh
└── verify.sh
```

## Các bước

### Step 1 — Thêm workflow vào repo goshop

Copy file `goshop-workflow.yml` vào repo `goshop` tại path `.github/workflows/docker.yml`:

```bash
# Trong repo goshop (KHÔNG phải deployment):
mkdir -p .github/workflows
cp <đường-dẫn-tới>/goshop-workflow.yml .github/workflows/docker.yml
git add .github/workflows/docker.yml
git commit -m "ci: build & push multi-arch image"
git push origin master
```

Theo dõi run: https://github.com/quangdangfit/goshop/actions

Lần đầu ~5-8 phút (build arm64 qua QEMU chậm). Lần sau ~1-3 phút (cache).

### Step 2 — Đặt package goshop public

Sau khi workflow chạy xong lần đầu, vào:
`https://github.com/users/quangdangfit/packages/container/goshop/settings`
→ **Change visibility** → **Public**.

(Skip nếu đã làm ở Phase 3.)

### Step 3 — Cài ArgoCD Image Updater

```bash
./install-image-updater.sh
```

Helm cài chart `argo/argocd-image-updater`.

### Step 4 — Tạo PAT cho AIU commit lên deployment repo

1. https://github.com/settings/tokens/new
2. Scope: `repo` (full control of private repos) — vì AIU sẽ git push
3. Note: `argocd-image-updater`
4. Copy token, export:
   ```bash
   export GIT_USER=quangdangfit
   export GIT_TOKEN=ghp_xxx
   ```

> Hoặc dùng GitHub App (an toàn hơn, scope token narrow hơn) — xem docs ArgoCD Image Updater.

### Step 5 — Seed git creds Secret

```bash
./apply.sh
```

Script này:
1. `envsubst` template `git-creds-secret.yaml.tpl` với `$GIT_USER`, `$GIT_TOKEN` → apply
2. Apply `goshop-app-updated.yaml` (Application có annotation AIU)

### Step 6 — Trigger build + observe

Trong repo goshop:
```bash
git commit --allow-empty -m "test: trigger ci"
git push origin master
```

Theo dõi:
1. GitHub Actions → workflow chạy → push image `ghcr.io/.../goshop:master-<sha>`
2. AIU log:
   ```bash
   kubectl -n argocd logs -l app.kubernetes.io/name=argocd-image-updater -f
   ```
   Tìm dòng "found new image..."
3. AIU commit lên deployment repo → tag mới trong `phases/05-helm/chart/goshop/values.yaml`
4. ArgoCD detect commit → sync → pod rolling restart với image mới

Tổng thời gian: 3-8 phút.

### Step 7 — Rollback path

Nếu image mới crash:
```bash
# 1. Git revert commit của AIU trong deployment repo, push
git -C <path-to-deployment> revert <sha-of-aiu-commit>
git -C <path-to-deployment> push

# 2. Hoặc ArgoCD rollback về revision trước:
kubectl -n argocd patch app goshop --type merge \
  -p '{"operation":{"sync":{"revision":"<git-sha-good>"}}}'
```

## Verify

```bash
./verify.sh
```

## Troubleshooting

| Triệu chứng | Lệnh | Fix |
|---|---|---|
| AIU không thấy image mới | `kubectl -n argocd logs -l app.kubernetes.io/name=argocd-image-updater` | Regex `allow-tags` không khớp; hoặc registry không trả tags (private + thiếu auth) |
| Git commit fail | log AIU | Sai PAT, hoặc thiếu scope `repo`. Test: `git clone https://$GIT_USER:$GIT_TOKEN@github.com/quangdangfit/deployment` |
| ArgoCD không sync sau AIU commit | UI → App → Sync status | Auto-sync chưa bật, hoặc commit có chỉ thị `[skip-ci]` |
| Workflow timeout build arm64 | Actions log | Tăng `timeout-minutes` lên 30, hoặc dùng self-hosted runner ARM |
| `denied: permission_denied` khi push ghcr | Actions log | Workflow thiếu `permissions: packages: write` |

## Cleanup

```bash
helm -n argocd uninstall argocd-image-updater
kubectl -n argocd delete secret git-creds
kubectl -n argocd patch app goshop --type=json -p='[{"op":"remove","path":"/metadata/annotations"}]'
```

---

→ **Next:** [Phase 9 — Production hardening](../09-hardening/)
