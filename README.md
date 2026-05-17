# Deployment

GitOps repo for a k3s cluster (Oracle Cloud, ARM64). One repo holds both **platform** (shared infra) and **apps** (one folder per app — values + Argo CD Application).

CI/CD follows the **GitOps pull model**: the app repo builds and pushes an image, Argo CD Image Updater bumps the tag in this repo, Argo CD syncs the change into the cluster. Nobody runs `kubectl apply` or `helm install` against prod by hand.

## Layout

```
platform/   # Shared infra — install once per cluster via install.sh
  ingress-nginx/      # HTTP/S entrypoint
  cert-manager/       # Automatic TLS (Let's Encrypt)
  external-secrets/   # ESO + Doppler ClusterSecretStore
  databases/          # Shared Postgres + Redis (ns: data)
  argocd/             # Argo CD + Image Updater + ghcr pull secret + git creds

charts/     # Reusable Helm chart library
  webapp/    # Generic workload: deploy + svc + optional ingress/PVC/ES/configmap/probes/imageupdater

apps/       # One folder per release — values + Argo CD Application only
  snapnews/    # Next.js + SQLite (persistence on, ES on)
  goshop-api/  # Go BE — multi-port (http+grpc), configmap mount, no ingress
  goshop-web/  # FE nginx — public ingress, proxies /api to goshop-api intra-cluster

learning/   # Previous README + 9-phase roadmap — reference, not runtime
```

## End-to-end workflow

From a commit on the app repo to a running pod with the new image:

```
+---------------------------------------------+
| App repo (e.g. quangdangfit/snapnews)       |
|                                             |
|   dev: git push main                        |
|              |                              |
|              v                              |
|     GitHub Actions: docker build + push     |
+---------------------|-----------------------+
                      v
              +---------------+
              |   ghcr.io     |  (image registry)
              +-------+-------+
                      ^   |
              poll 2m |   | pull image
                      |   v
+---------------------|----------------------+
| Deployment repo (this)                     |
|                                            |
|  Image Updater  -- git push -->  values    |
|                                  (apps/X/  |
|                                  values.   |
|                                   yaml)    |
+-------------------|------------------------+
                    | poll 3m (Argo CD)
                    v
+--------------------------------------------+
| k3s cluster                                |
|                                            |
|  Argo CD --> render Helm (chart + values)  |
|         --> diff vs live state             |
|         --> server-side apply              |
|         --> Deployment controller          |
|         --> kubelet pulls image            |
|         --> Pod running new tag            |
+--------------------------------------------+
```

**Key idea:** the image registry and the git repo are the only sources of truth. The cluster only *pulls*; nothing is *pushed* into it.

## Stage 1 — CI builds and pushes the image

```
dev          GitHub          GitHub Actions          ghcr.io
 |              |                   |                   |
 | git push     |                   |                   |
 |  main(sha)   |                   |                   |
 |------------->|                   |                   |
 |              | trigger workflow  |                   |
 |              |------------------>|                   |
 |              |                   | buildx            |
 |              |                   | --platform        |
 |              |                   |   linux/arm64     |
 |              |                   |------------------>| docker push
 |              |                   |                   |   :main-abc1234
```

The app repo is only responsible for **building the image** and **pushing it to ghcr**. It never touches k8s manifests. The tag must:

- include **branch + short sha** (e.g. `main-abc1234`) — immutable, easy to roll back;
- match the `allowTags` regex used by Image Updater (stage 2);
- be built for `linux/arm64` (the cluster is Oracle ARM).

## Stage 2 — Image Updater spots the new tag and writes back to git

```
Image Updater          ghcr.io               deployment repo (main)
     |                    |                            |
     | every 2m           |                            |
     |------------------->|                            |
     | list tags                                       |
     |<-------------------|                            |
     | (newest = main-abc1234)                         |
     |                                                 |
     | matches allowTags regex, differs from current   |
     |                                                 |
     | git clone main                                  |
     |------------------------------------------------>|
     | rewrite apps/snapnews/values.yaml:              |
     |   image.tag: main-abc1234                       |
     | git commit "build: automatic update of snapnews"|
     | git push (auth via GHCR_USER + PAT)             |
     |------------------------------------------------>|
```

Tag selection + write-back are configured by `charts/webapp/templates/imageupdater.yaml` (rendered from values, the `ImageUpdater` CR lives in the `argocd` namespace). Git/ghcr auth is set up once by `platform/argocd/image-updater/install.sh`.

## Stage 3 — Argo CD spots the new commit, renders, applies

```
Argo CD controller    repo-server (helm)    deployment repo    k8s API
       |                    |                      |              |
       | every 3m (or webhook)                     |              |
       |------------------------------------------>|              |
       | fetch HEAD apps/snapnews/*                |              |
       |<------------------------------------------|              |
       |                                                          |
       | render chart                                             |
       |------------------->|                                     |
       | charts/webapp +                                          |
       | apps/snapnews/values.yaml                                |
       |<-------------------|                                     |
       | manifests: Deployment, Service, Ingress,                 |
       |            PVC, ExternalSecret, ImageUpdater             |
       |                                                          |
       | diff vs live (respecting ignoreDifferences)              |
       |                                                          |
       | if OutOfSync and automated sync:                         |
       | server-side apply manifests                              |
       |--------------------------------------------------------->|
       |<---------------------------------------------------------|
       | applied (Deployment updated)                             |
```

`apps/<name>/application.yaml` is an Argo CD Application CR declaring `repoURL`, `path: charts/<chart>`, `valueFiles: apps/<name>/values.yaml`, and `syncPolicy.automated`. It also carries an **`ignoreDifferences`** block for `ExternalSecret` — the ESO controller defaults a handful of fields that Helm doesn't render, which would otherwise leave the app permanently `OutOfSync`.

## Stage 4 — k8s rollout pulls the new image

```
k8s API           Deployment ctrl     kubelet           ghcr.io       Pod
   |                    |                |                 |           |
   | spec image=        |                |                 |           |
   |  ...:main-abc1234  |                |                 |           |
   |------------------->|                |                 |           |
   |                    | create new RS, scale up          |           |
   |                    |--------------->|                 |           |
   |                                     | pull image      |           |
   |                                     | (ghcr-pullsecret)           |
   |                                     |---------------->|           |
   |                                     |<----------------|           |
   |                                     | start container             |
   |                                     |---------------------------->|
   |                                                                   | entrypoint:
   |                                                                   |  db migrate
   |                                                                   |  exec server
   |                    | scale down old RS                            |
   |<-------------------|                                              |
```

The `ghcr-pullsecret` secret already exists in the `default` and `argocd` namespaces (created by `platform/argocd/install.sh` plus the image-updater installer). The pod reads env vars from a ConfigMap (rendered from chart `config:`) and a Secret (synced from Doppler by ESO).

## Stage 5 — Secrets: Doppler → ESO → k8s Secret

```
  +-----------+                                  +------------------+
  |  Doppler  |  ClusterSecretStore "doppler"    | external-secrets |
  |  project  |--------------------------------->|    controller    |
  +-----------+        (Service Token)           +--------+---------+
                                                          |
                          ExternalSecret CR               |
                          (ns: default,                   |
                           refreshInterval: 1h) --------->|
                                                          v
                                                  +---------------+
                                                  |  k8s Secret   |
                                                  | snapnews-     |
                                                  |   secrets     |
                                                  +-------+-------+
                                                          |
                                                          v
                                                    +----------+
                                                    | Pod env  |
                                                    +----------+
```

The `webapp` chart auto-renders the `ExternalSecret` from `externalSecret.keys`. `goshop` uses a standalone `apps/goshop/externalsecret.yaml` (its chart doesn't manage ES). The Doppler token is installed once via `platform/external-secrets/install.sh`.

## Bootstrap a fresh cluster

Run once when provisioning a new cluster:

```bash
export KUBECONFIG=$HOME/.kube/config

# 1. Platform — install in order (each depends on the previous)
./platform/ingress-nginx/install.sh
./platform/cert-manager/install.sh

export DOPPLER_TOKEN=dp.st.prd.xxx
./platform/external-secrets/install.sh

./platform/databases/apply.sh

./platform/argocd/install.sh

export GHCR_USER=quangdangfit
export GHCR_TOKEN=ghp_xxx          # PAT scopes: repo + read:packages + write:packages
./platform/argocd/image-updater/install.sh

# 2. Apply the Application CR for each app — Argo handles the rest
kubectl apply -f apps/snapnews/application.yaml
kubectl apply -f apps/goshop-api/application.yaml
kubectl apply -f apps/goshop-api/externalsecret.yaml   # standalone ES (not rendered by webapp here)
kubectl apply -f apps/goshop-web/application.yaml
```

From here on, every push to an app repo's main branch propagates to the cluster automatically — no SSH, no manual apply.

## Deploy a brand-new repo — checklist

Assume a new app called `myapp`.

### A. In the app repo (e.g. `quangdangfit/myapp`)

1. **Dockerfile** — multi-stage, ARM64-compatible base image (`node:20-alpine`, `golang:1.23-alpine`, …). Run as non-root and expose a single port.
2. **GitHub Actions** — build + push workflow:
   ```yaml
   # .github/workflows/build.yml (abridged)
   on: { push: { branches: [main] } }
   jobs:
     build:
       runs-on: ubuntu-latest
       permissions: { contents: read, packages: write }
       steps:
         - uses: actions/checkout@v4
         - uses: docker/setup-qemu-action@v3
         - uses: docker/setup-buildx-action@v3
         - uses: docker/login-action@v3
           with: { registry: ghcr.io, username: ${{ github.actor }}, password: ${{ secrets.GITHUB_TOKEN }} }
         - uses: docker/build-push-action@v6
           with:
             platforms: linux/arm64
             push: true
             tags: ghcr.io/${{ github.repository }}:main-${{ github.sha }}
   ```
   The tag must look like `main-<sha>` (or a matching regex) so Image Updater can pick it up.
3. **Image visibility** — on ghcr, make the package public, *or* link it to the `deployment` repo so the existing pull secret has access.
4. **Secrets** — push the required keys to Doppler (project = app name). The Service Token consumed by ESO already exists.

### B. In this repo (`deployment`)

All apps use **`charts/webapp`** — one generic chart, behavior driven by `values.yaml`. For multi-service apps (BE + FE), create one release per service (one folder under `apps/`) rather than packing them into a single chart.

```bash
mkdir -p apps/myapp
```

Create `apps/myapp/values.yaml` (copy `apps/snapnews/values.yaml` and tweak):

```yaml
replicaCount: 1
image:
  repository: ghcr.io/quangdangfit/myapp
  tag: "main"        # placeholder — Image Updater bumps it
  pullPolicy: Always
containerPort: 8080
service: { type: ClusterIP, port: 80 }
ingress:
  enabled: true
  className: nginx
  host: myapp.cunghoclaptrinh.online
  tlsSecretName: myapp-tls
  clusterIssuer: letsencrypt-prod
env:
  NODE_ENV: production
envFromSecret: myapp-secrets         # if needed
persistence: { enabled: false }      # enable for PVC-backed storage
externalSecret:
  enabled: true                      # if the app reads secrets from Doppler
  keys: [API_KEY, OTHER_KEY]
imageUpdater:
  enabled: true
  allowTags: "regexp:^main-[0-9a-f]{7,40}$"
  repo: git@github.com:quangdangfit/deployment.git
  branch: main
  valuesPath: apps/myapp/values.yaml
resources:
  requests: { cpu: 50m,  memory: 128Mi }
  limits:   { cpu: 500m, memory: 512Mi }
```

Create `apps/myapp/application.yaml` (copy from `apps/snapnews/application.yaml`, change the name):

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: myapp
  namespace: argocd
  finalizers: [resources-finalizer.argocd.argoproj.io]
spec:
  project: default
  sources:
    - repoURL: https://github.com/quangdangfit/deployment
      targetRevision: main
      path: charts/webapp
      helm:
        releaseName: myapp
        valueFiles: [$values/apps/myapp/values.yaml]
    - repoURL: https://github.com/quangdangfit/deployment
      targetRevision: main
      ref: values
  destination:
    server: https://kubernetes.default.svc
    namespace: default
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    syncOptions: [CreateNamespace=true, ServerSideApply=true]
  ignoreDifferences:                                          # if using ExternalSecret
    - group: external-secrets.io
      kind: ExternalSecret
      jqPathExpressions:
        - .spec.data[].remoteRef.conversionStrategy
        - .spec.data[].remoteRef.decodingStrategy
        - .spec.data[].remoteRef.metadataPolicy
        - .spec.data[].remoteRef.nullBytePolicy
      jsonPointers: [/spec/target/deletionPolicy]
```

Commit, push, and apply the Application CR once:

```bash
git add apps/myapp/
git commit -m "apps: add myapp"
git push
kubectl apply -f apps/myapp/application.yaml    # one-time bootstrap; everything else goes through git
```

### C. Verify

```bash
kubectl -n argocd get app myapp
kubectl -n default get pod -l app.kubernetes.io/instance=myapp
kubectl -n default get ingress,svc,externalsecret -l app.kubernetes.io/instance=myapp
curl -I https://myapp.cunghoclaptrinh.online
```

From now on, each push to the app's main branch ends up as a pod restart within ~5 minutes. To force an immediate sync: `kubectl -n argocd annotate app myapp argocd.argoproj.io/refresh=hard --overwrite`.

## Troubleshooting

| Symptom | What to check |
|---|---|
| App stays `OutOfSync` because of `ExternalSecret` | `ignoreDifferences` block missing (see the template above) |
| Pod stuck on `ImagePullBackOff` | image not public / missing `ghcr-pullsecret` in the app namespace |
| Tag never bumps | `allowTags` regex doesn't match; check `kubectl -n argocd logs deploy/argocd-image-updater` |
| Argo can't see a new commit | hard-refresh, or wait up to 3 minutes; check `kubectl -n argocd logs deploy/argocd-repo-server` |
| Secret comes through empty | wrong Doppler token, or key name mismatch; `kubectl describe es <name>` |
| DB migrate fails on startup | inspect the entrypoint container log; confirm the PVC is mounted at the expected path |

## Learning

`learning/phases/` is a 9-phase roadmap (k3s → ingress → helm → argocd → ESO → CI/CD → hardening). Read it in order to understand *why* `platform/` and `apps/` are organized the way they are. `learning/README-old.md` is the previous short-form README.
