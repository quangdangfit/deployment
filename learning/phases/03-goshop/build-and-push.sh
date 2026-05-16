#!/usr/bin/env bash
# Build & push multi-arch images:
#   - ghcr.io/$GHCR_USER/goshop:$TAG       — BE (Go)
#   - ghcr.io/$GHCR_USER/goshop-web:$TAG   — FE (React/Vite + nginx)
# Cần: docker (Desktop hoặc engine), buildx plugin, QEMU.
set -euo pipefail

: "${GHCR_USER:?export GHCR_USER=<github-username>}"
: "${GHCR_TOKEN:?export GHCR_TOKEN=<PAT with write:packages>}"

TAG="${TAG:-master}"
SRC_DIR="${SRC_DIR:-/tmp/goshop-src}"
REPO_URL="https://github.com/quangdangfit/goshop.git"
BRANCH="${BRANCH:-master}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "==> Cloning/updating $REPO_URL -> $SRC_DIR"
if [[ -d "$SRC_DIR/.git" ]]; then
  git -C "$SRC_DIR" fetch --depth=1 origin "$BRANCH"
  git -C "$SRC_DIR" checkout -f "origin/$BRANCH"
else
  git clone --depth=1 -b "$BRANCH" "$REPO_URL" "$SRC_DIR"
fi

# Copy Dockerfile + nginx.conf vào web/ (goshop repo chưa có sẵn file Dockerfile cho FE)
echo "==> Injecting FE Dockerfile + nginx.conf into $SRC_DIR/web/"
cp "$SCRIPT_DIR/web/Dockerfile" "$SRC_DIR/web/Dockerfile"
cp "$SCRIPT_DIR/web/nginx.conf" "$SRC_DIR/web/nginx.conf"

echo "==> Logging in to ghcr.io"
echo "$GHCR_TOKEN" | docker login ghcr.io -u "$GHCR_USER" --password-stdin

echo "==> Ensuring QEMU emulators are installed"
docker run --rm --privileged tonistiigi/binfmt --install all >/dev/null

echo "==> Ensuring buildx builder exists"
docker buildx inspect multi-arch >/dev/null 2>&1 || \
  docker buildx create --name multi-arch --use

echo
echo "==> [1/2] Building & pushing BE: ghcr.io/$GHCR_USER/goshop:$TAG"
docker buildx build \
  --builder multi-arch \
  --platform linux/amd64,linux/arm64 \
  --tag "ghcr.io/$GHCR_USER/goshop:$TAG" \
  --push \
  "$SRC_DIR"

echo
echo "==> [2/2] Building & pushing FE: ghcr.io/$GHCR_USER/goshop-web:$TAG"
docker buildx build \
  --builder multi-arch \
  --platform linux/amd64,linux/arm64 \
  --tag "ghcr.io/$GHCR_USER/goshop-web:$TAG" \
  --push \
  "$SRC_DIR/web"

echo
echo "==> Done. Both images at tag :$TAG"
echo "    Mark BOTH packages public (settings page):"
echo "    https://github.com/users/$GHCR_USER/packages/container/goshop/settings"
echo "    https://github.com/users/$GHCR_USER/packages/container/goshop-web/settings"
