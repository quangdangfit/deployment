# deployment

Mono-repo for personal-project deployments.

## Layout

```
deployment/
├── clusters/      # cluster infra + ArgoCD platform (created during implementation)
│   └── k3s/       # single-node k3s on Oracle A1.Flex
├── docs/          # design specs and implementation plans
└── goshop/        # GitOps deployment for quangdangfit/goshop — see goshop/README.md
```

Each project owns:
- its workload manifests under `<project>/{apps,charts,manifests}/`
- its own runbooks and secrets mapping

## Active projects

| Project | Cluster | Status   |
|---------|---------|----------|
| goshop  | k3s     | In setup |

## Conventions

- ArgoCD App-of-Apps per cluster, GitOps-native after bootstrap
- Doppler is the source of truth for secrets, mounted via External Secrets Operator
- Bitnami charts for stateful workloads (Postgres, Redis)
- All workloads enforce `runAsNonRoot`, `readOnlyRootFilesystem`, `drop: [ALL]`
