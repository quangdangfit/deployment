# Deployment

GitOps repo cho k3s cluster trên Oracle Cloud (ARM64). Tách **platform** (infra dùng chung) khỏi **apps** (mỗi app 1 thư mục, chỉ chứa values + Application).

## Layout

```
platform/        # Infra dùng chung — cài 1 lần / cluster
  ingress-nginx/
  cert-manager/      # + ClusterIssuer letsencrypt-prod
  external-secrets/  # ESO + Doppler ClusterSecretStore
  argocd/            # ArgoCD + ingress
    image-updater/   # AIU + ghcr pull secret + git write-back creds
  databases/         # Shared Postgres + Redis trong ns `data`
    postgres/
    redis/

charts/          # Helm chart library (reusable templates)
  goshop/        # Chart riêng cho goshop (api + web trong 1 chart)
  webapp/        # Chart generic single-service (deploy + svc + ingress)

apps/            # Mỗi app 1 thư mục — chỉ values + Argo CD Application
  goshop/        # application.yaml, values.yaml, externalsecret.yaml, imageupdater.yaml
  hello/         # Sample app dùng charts/webapp — copy thư mục này để bootstrap app mới

learning/        # Roadmap 9 phases (00..09) — đọc tham khảo để hiểu từng layer
  phases/
```

## Bootstrap cluster mới

```bash
export KUBECONFIG=$HOME/.kube/config

# 1. Platform — chạy theo thứ tự (mỗi cái phụ thuộc cái trước)
./platform/ingress-nginx/install.sh
./platform/cert-manager/install.sh

export DOPPLER_TOKEN=dp.st.prd.xxx
./platform/external-secrets/install.sh

./platform/databases/apply.sh

./platform/argocd/install.sh

export GHCR_USER=quangdangfit
export GHCR_TOKEN=ghp_xxx  # PAT: repo + read:packages
./platform/argocd/image-updater/install.sh

# 2. Apply từng app
kubectl apply -f apps/goshop/application.yaml
kubectl apply -f apps/goshop/externalsecret.yaml
kubectl apply -f apps/goshop/imageupdater.yaml
```

## Thêm app mới

Copy `apps/hello/` → `apps/<name>/`, sửa `values.yaml` + tên trong `application.yaml`. Nếu cần secrets/auto image bump, copy thêm `externalsecret.yaml` / `imageupdater.yaml` từ `apps/goshop/`.

## Learning

Thư mục [`learning/phases/`](learning/phases/) là roadmap 9 phases (k3s → ingress → helm → argocd → ESO → CI/CD → hardening) — vẫn chạy được độc lập, dùng để hiểu lý do tại sao platform/apps được tổ chức như hiện tại.
