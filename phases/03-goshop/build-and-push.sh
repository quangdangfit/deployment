#!/usr/bin/env bash
# Build multi-arch image goshop và push lên ghcr.io.
# Cần: docker (Desktop hoặc engine), buildx plugin, QEMU.
set -euo pipefail

: "${GHCR_USER:?export GHCR_USER=<github-username>}"
: "${GHCR_TOKEN:?export GHCR_TOKEN=<PAT with write:packages>}"

IMAGE="ghcr.io/${GHCR_USER}/goshop"
TAG="${TAG:-master}"
SRC_DIR="${SRC_DIR:-/tmp/goshop-src}"
REPO_URL="https://github.com/quangdangfit/goshop.git"
BRANCH="${BRANCH:-master}"

echo "==> Cloning/updating $REPO_URL -> $SRC_DIR"
if [[ -d "$SRC_DIR/.git" ]]; then
  git -C "$SRC_DIR" fetch --depth=1 origin "$BRANCH"
  git -C "$SRC_DIR" checkout -f "origin/$BRANCH"
else
  git clone --depth=1 -b "$BRANCH" "$REPO_URL" "$SRC_DIR"
fi

echo "==> Logging in to ghcr.io"
echo "$GHCR_TOKEN" | docker login ghcr.io -u "$GHCR_USER" --password-stdin

echo "==> Ensuring QEMU emulators are installed (for arm64 build on amd64 host)"
docker run --rm --privileged tonistiigi/binfmt --install all >/dev/null

echo "==> Ensuring buildx builder exists"
docker buildx inspect multi-arch >/dev/null 2>&1 || \
  docker buildx create --name multi-arch --use

echo "==> Building & pushing $IMAGE:$TAG (linux/amd64,linux/arm64)"
docker buildx build \
  --builder multi-arch \
  --platform linux/amd64,linux/arm64 \
  --tag "$IMAGE:$TAG" \
  --push \
  "$SRC_DIR"

echo
echo "==> Done. Image: $IMAGE:$TAG"
echo "    Now mark the package public:"
echo "    https://github.com/$GHCR_USER/goshop/pkgs/container/goshop"
