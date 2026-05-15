# GoShop on k3s (Oracle A1.Flex) — Design

**Date:** 2026-05-15
**Status:** Approved, ready for implementation plan
**Supersedes:** `clusters/oke/` (OKE pivoted away from due to ARM capacity issues)
**Related:** `goshop/k3s-plan.md` (initial brainstorm), `goshop/devops-plan.md` (rationale)

---

## Goal

Replace the OKE-based deployment of `goshop` with a single-node k3s cluster on a pre-existing
Oracle Cloud A1.Flex VM. Keep the existing GitOps model (ArgoCD App-of-Apps, Doppler secrets,
Bitnami stateful charts) so workload manifests under `goshop/` are reusable without rewrite.

## Non-goals (deferred)

- High availability (single-node is accepted SPOF for a personal project).
- Monitoring stack (Prometheus / Grafana / Loki). Will be added later once the app is stable.
- Backups (pg_dump, etcd snapshot upload, Velero). Accepted risk for the initial bring-up.
- OpenTofu/IaC for the VM. The VM already exists and recovery will be manual.

## Existing context

- VM: `VM.Standard.A1.Flex`, **2 OCPU / 16 GB RAM**, Ubuntu 22.04 ARM, already provisioned with a
  reserved public IP and SSH access via `~/.ssh/oci_goshop`.
- Domain: `goshop.cunghoclaptrinh.online` managed in Cloudflare.
- Secrets: Doppler project `goshop`, env `prod`, service token issued.
- Image: `ghcr.io/quangdangfit/goshop` (public).

## Architecture

```
                 Internet
                    │
              Cloudflare DNS (proxy OFF initially for HTTP-01)
                    │
            ┌───────▼────────┐
            │   Oracle VM    │  A1.Flex 2 OCPU / 16GB, Ubuntu 22.04
            │ Public IP:443  │
            │                │
            │  ┌──────────┐  │   ingress-nginx (DaemonSet, hostNetwork)
            │  │  nginx   │  │   binds 80/443 directly on the host
            │  └────┬─────┘  │
            │       │        │
            │  ┌────▼──────────────────────────────┐
            │  │  k3s (single-node server+agent)   │
            │  │  - traefik disabled               │
            │  │  - servicelb disabled             │
            │  │  - local-path-provisioner (PVCs)  │
            │  │                                   │
            │  │  Namespaces:                      │
            │  │   argocd            (GitOps)      │
            │  │   cert-manager      (TLS)         │
            │  │   external-secrets  (Doppler)     │
            │  │   ingress-nginx                   │
            │  │   data              (Postgres,    │
            │  │                      Redis)       │
            │  │   goshop            (workload)    │
            │  └───────────────────────────────────┘
            └────────────────┘
```

### Component responsibilities

| Component | Purpose | Install method |
|---|---|---|
| k3s | Kubernetes control plane + kubelet on one node | shell installer (`get.k3s.io`) |
| ingress-nginx | L7 ingress, binds host 80/443 via `hostNetwork: true` | Helm (bootstrap), then ArgoCD |
| cert-manager | Let's Encrypt HTTP-01 issuer for `*.cunghoclaptrinh.online` | Helm (bootstrap), then ArgoCD |
| ArgoCD | GitOps reconciler, single replica | Helm (bootstrap), then self-managed |
| External Secrets Operator | Pulls secrets from Doppler into k8s Secrets | Helm (bootstrap), then ArgoCD |
| local-path-provisioner | Default StorageClass for PVCs (host-path) | bundled with k3s |
| Postgres (Bitnami) | App database | ArgoCD-managed Helm release |
| Redis (Bitnami) | App cache | ArgoCD-managed Helm release |
| goshop | Application workload | ArgoCD App pointing at `goshop/apps/` |

## Resource budget (16 GB RAM)

| Component | Approx RAM |
|---|---|
| OS + k3s control plane + kubelet | ~2.0 GB |
| ingress-nginx + cert-manager | ~0.4 GB |
| ArgoCD (single replica, HA off) | ~1.0 GB |
| External Secrets Operator | ~0.1 GB |
| Postgres + Redis | ~1.3 GB |
| goshop (2 replicas × 256 MB) | ~0.5 GB |
| **Subtotal** | **~5.3 GB** |
| Headroom (page cache, future monitoring) | ~10 GB |

Comfortable. A slim Prometheus stack (~3 GB) fits later without re-sizing.

## Traffic & TLS path

1. DNS: Cloudflare A record `goshop.cunghoclaptrinh.online → <VM public IP>`, **proxy OFF** initially
   so `cert-manager` can complete HTTP-01 challenges. After certs issue successfully the proxy
   can be re-enabled.
2. ingress-nginx runs as a DaemonSet with `hostNetwork: true` and `hostPort` on 80/443. No
   Service of type LoadBalancer is needed.
3. cert-manager issues certs via Let's Encrypt HTTP-01; Ingress resources reference the
   ClusterIssuer through `cert-manager.io/cluster-issuer` annotation.

## Firewall

VM NSG/Security List opens:

- 22/tcp — SSH (restrict to home IP if practical)
- 80/tcp, 443/tcp — public ingress
- 6443/tcp — Kubernetes API, restricted to local admin IP only (never public)

The Oracle Ubuntu image ships with iptables DROP rules that block k3s. Either insert ACCEPT
rules for 6443/80/443 and persist via `netfilter-persistent`, or purge
`iptables-persistent` / `netfilter-persistent` outright and reboot. This is required before
k3s will be reachable.

## Repository layout

New directory mirroring `clusters/oke/`:

```
clusters/
  k3s/
    README.md                    # VM IP, SSH key path, install one-liner, recovery notes
    install.sh                   # idempotent k3s install + iptables fix
    bootstrap/
      argocd-values.yaml         # single replica, ingress host
      ingress-nginx-values.yaml  # hostNetwork, DaemonSet
      README.md                  # one-shot bootstrap commands
    platform/
      root.yaml                  # App-of-Apps for the cluster
      ingress-nginx.yaml         # ArgoCD App (after bootstrap takeover)
      cert-manager.yaml
      cluster-issuer.yaml
      external-secrets.yaml
      argocd-project.yaml
  oke/                           # kept as reference, not deleted
goshop/                          # unchanged — manifests are cluster-agnostic
```

## Phased rollout

1. **Phase 1 — VM prep.** Open ports in NSG, apply iptables fix, set timezone, disable swap.
2. **Phase 2 — Install k3s.** Run installer with `--disable traefik --disable servicelb
   --tls-san <PUBLIC_IP> --tls-san goshop.cunghoclaptrinh.online`. Copy kubeconfig to local,
   rewrite server URL to public IP, verify node Ready.
3. **Phase 3 — Bootstrap platform.** Helm install (in this order): ingress-nginx → point
   DNS → cert-manager + ClusterIssuer → ArgoCD → External Secrets Operator + Doppler
   `SecretStore`.
4. **Phase 4 — GitOps takeover.** Create `clusters/k3s/platform/root.yaml`. ArgoCD sync
   adopts platform components, then sync `goshop/apps/root.yaml` to bring up Postgres,
   Redis, and the app. Verify `https://goshop.cunghoclaptrinh.online/healthz`.
5. **Phase 5 — Deferred.** Monitoring, backups (pg_dump + etcd snapshot to Object Storage),
   recovery runbook. Tracked as separate work items, not part of this spec.

## Risks & accepted tradeoffs

- **SPOF.** Single VM, no backups in Phase 0–4. If the VM dies, the app dies and data is
  lost until Phase 5 ships. Acceptable for a personal project; revisit before storing
  anything irreplaceable.
- **Manual VM.** No IaC. Recovery means re-creating the VM in the OCI console and re-running
  `install.sh`. Documented in `clusters/k3s/README.md`.
- **No HA for ingress.** ingress-nginx as a DaemonSet on one node is fine until the node
  count grows. Same DaemonSet config works unchanged on multi-node later.
- **Cloudflare proxy off at bring-up.** Required for HTTP-01. Re-enable proxy after the first
  cert renewal succeeds, or switch to DNS-01 if proxying is required from day one.

## Success criteria

- `kubectl get nodes` shows the single node Ready from the local workstation.
- ArgoCD UI reachable, all platform Apps Synced + Healthy.
- `curl https://goshop.cunghoclaptrinh.online/healthz` returns 200 with a valid Let's Encrypt cert.
- Doppler-sourced secrets visible as `Secret` objects in the `goshop` namespace.
