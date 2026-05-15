# k3s — single-node (Oracle A1.Flex)

| Field | Value |
|---|---|
| VM shape | VM.Standard.A1.Flex, 2 OCPU, 16 GB RAM |
| OS | Ubuntu 22.04 ARM |
| Public IP | _set in Doppler / local env: VM_IP_ |
| SSH key | `~/.ssh/oci_goshop` |
| Domain | `goshop.cunghoclaptrinh.online` (Cloudflare) |
| kubeconfig | `~/.kube/k3s-goshop.yaml` |

## Bring-up

1. Open ports 22, 80, 443 in the OCI NSG. Restrict 6443 to your admin IP.
2. SSH in and run `clusters/k3s/install.sh` (idempotent).
3. Copy `/etc/rancher/k3s/k3s.yaml` locally and rewrite the `server:` URL to `https://<VM_IP>:6443`.
4. Run the bootstrap commands in `clusters/k3s/bootstrap/README.md`.
5. Apply `clusters/k3s/platform/root.yaml` to let ArgoCD take over.
6. Apply `goshop/apps/root.yaml` to bring up the workload.

## Recovery

VM is manual (no IaC). To rebuild: provision a new A1.Flex with the reserved public IP,
re-run `install.sh`, restore Postgres from backup (Phase 5 — not yet implemented),
then re-apply the platform and workload roots.
