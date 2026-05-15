# Bootstrap — one-shot Helm install

Run these once from your workstation after `install.sh` has put the cluster in Ready state
and `$KUBECONFIG` points at the new node.

```bash
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo add jetstack https://charts.jetstack.io
helm repo add argo https://argoproj.github.io/argo-helm
helm repo add external-secrets https://charts.external-secrets.io
helm repo update

# 1. ingress-nginx (hostNetwork DaemonSet)
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  -n ingress-nginx --create-namespace \
  -f clusters/k3s/bootstrap/ingress-nginx-values.yaml

# 2. cert-manager + CRDs
helm upgrade --install cert-manager jetstack/cert-manager \
  -n cert-manager --create-namespace \
  --set installCRDs=true

# 3. ArgoCD
helm upgrade --install argocd argo/argo-cd \
  -n argocd --create-namespace \
  -f clusters/k3s/bootstrap/argocd-values.yaml

# 4. External Secrets Operator
helm upgrade --install external-secrets external-secrets/external-secrets \
  -n external-secrets --create-namespace \
  --set installCRDs=true
```

After all four Helm releases are healthy, apply the platform App-of-Apps:

```bash
kubectl apply -f clusters/k3s/platform/root.yaml
```
