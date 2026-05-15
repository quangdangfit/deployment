#!/usr/bin/env bash
set -euo pipefail
: "${KUBECONFIG:?export KUBECONFIG=\$HOME/.kube/k3s-goshop.yaml}"

fail=0
check() { local m="$1"; shift; "$@" >/dev/null 2>&1 && echo "  [OK]   $m" || { echo "  [FAIL] $m"; fail=1; }; }

check "argocd-image-updater pod Ready" \
  kubectl -n argocd wait --for=condition=Ready pod -l app.kubernetes.io/name=argocd-image-updater --timeout=10s
check "git-creds Secret exists" \
  kubectl -n argocd get secret git-creds
check "Application has Image Updater annotation" \
  bash -c "kubectl -n argocd get app goshop -o jsonpath='{.metadata.annotations}' | grep -q argocd-image-updater"

# Latest commit author == AIU? (indicator: AIU đã commit thành công ít nhất 1 lần)
last_author=$(git log -1 --pretty=%an 2>/dev/null || echo "")
if [[ "$last_author" =~ image[-_ ]updater ]]; then
  echo "  [OK]   Last commit appears to be from Image Updater"
else
  echo "  [INFO] Last commit author: $last_author (push goshop code để trigger CI và AIU)"
fi

exit $fail
