# GoShop Deployment — Phased Learning Roadmap

Triển khai [goshop](https://github.com/quangdangfit/goshop) (e-commerce viết bằng Go) lên Kubernetes theo lộ trình **từ cơ bản đến nâng cao**. Mỗi phase là một bài học độc lập với mục tiêu và "ngắt" rõ ràng — bạn có thể dừng ở bất cứ phase nào và vẫn có một hệ thống chạy được.

## Hạ tầng

- **VM:** Oracle Cloud Always Free A1.Flex — 2 OCPU ARM64, 16 GB RAM, Ubuntu 22.04
- **K8s:** [k3s](https://k3s.io) (single-node, bundled containerd)
- **DNS:** Cloudflare → `goshop.cunghoclaptrinh.online`
- **Container registry:** ghcr.io (free, public)

## Roadmap

| # | Phase | Mục tiêu | Tool mới |
|---|---|---|---|
| **0** | [VM + k3s foundation](phases/00-vm-k3s/) | Có cluster k8s Ready | k3s, kubectl |
| **1** | [Hello-world](phases/01-hello-world/) | Hiểu Namespace/Deployment/Service qua nginx | kubectl primitives |
| **2** | [Postgres + Redis raw](phases/02-data/) | DB chạy trên k8s, kết nối được | StatefulSet, PVC, Secret |
| **3** | [Build & deploy goshop](phases/03-goshop/) | App trả 200 ở `IP:NodePort` | docker buildx, ghcr.io |
| **4** | [Ingress + HTTPS](phases/04-ingress-tls/) | `https://goshop.domain` xanh khoá | Helm, ingress-nginx, cert-manager |
| **5** | [Helm chart cho goshop](phases/05-helm/) | Deploy bằng `helm install` | helm templating |
| **6** | [GitOps với ArgoCD](phases/06-argocd/) | Push git → auto deploy | ArgoCD |
| **7** | [Doppler + ESO](phases/07-doppler-eso/) | Hết secret hardcode | External Secrets Operator |
| **8** | [CI/CD build image](phases/08-cicd/) | Commit code → image mới → auto rollout | GitHub Actions, Image Updater |
| **9** | [Production hardening](phases/09-hardening/) | Backup, HPA, NetworkPolicy, monitoring | Prometheus, pg_dump CronJob |

## Cách dùng repo này

Đi tuần tự từ Phase 0. Mỗi thư mục `phases/NN-*/` có:

- `README.md` — **đọc trước**: mục tiêu, kiến thức nền, các bước với giải thích "tại sao", verify, troubleshooting, cleanup
- Một hoặc nhiều script `.sh` để execute từng đoạn
- Folder `manifests/` (nếu phase đó dùng YAML)

Không phase nào yêu cầu trạng thái phase sau — bạn có thể tự tin xoá hết và làm lại.

## Reference docs

- Spec gốc thiết kế hạ tầng: [docs/superpowers/specs/2026-05-15-k3s-goshop-design.md](docs/superpowers/specs/2026-05-15-k3s-goshop-design.md) (có thể đã lệch so với roadmap phased)
