#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

usage() {
	cat <<'EOF'
Usage: ./scripts/package-vsix.sh [package args...]

Builds and packages GitLens into a .vsix inside Docker.
The host only needs Docker; Node, pnpm, and vsce run inside the container.

Examples:
  ./scripts/package-vsix.sh
  ./scripts/package-vsix.sh --out ./gitlens-local.vsix

Environment overrides:
  NODE_IMAGE=node:22.18.0-bookworm
  PNPM_VERSION=10.33.2
  NPM_REGISTRY=https://registry.npmmirror.com
  FALLBACK_NPM_REGISTRY=https://registry.npmjs.org
  COREPACK_NPM_REGISTRY=https://registry.npmmirror.com
  DOCKER_PULL=missing
  DOCKER_PLATFORM=linux/amd64

If Docker Hub is slow, point NODE_IMAGE at your Docker mirror, for example:
  NODE_IMAGE=docker.m.daocloud.io/library/node:22.18.0-bookworm ./scripts/package-vsix.sh
EOF
}

case "${1:-}" in
	-h|--help)
		usage
		exit 0
		;;
esac

command -v docker >/dev/null 2>&1 || {
	echo "docker is required but was not found in PATH" >&2
	exit 1
}

NODE_IMAGE="${NODE_IMAGE:-node:22.18.0-bookworm}"
DOCKER_PULL="${DOCKER_PULL:-missing}"
DOCKER_PLATFORM="${DOCKER_PLATFORM:-}"

PRIMARY_NPM_REGISTRY="${NPM_REGISTRY:-https://registry.npmmirror.com}"
FALLBACK_NPM_REGISTRY="${FALLBACK_NPM_REGISTRY:-https://registry.npmjs.org}"
COREPACK_NPM_REGISTRY="${COREPACK_NPM_REGISTRY:-https://registry.npmmirror.com}"

PNPM_VERSION="${PNPM_VERSION:-$(grep -o '"packageManager": "pnpm@[^"]*"' package.json | sed 's/.*pnpm@\([^"]*\).*/\1/' || true)}"
PNPM_VERSION="${PNPM_VERSION:-10.33.2}"

log() {
	printf '\033[1;34m[package-vsix]\033[0m %s\n' "$*"
}

mkdir -p .work/docker-bin .work/docker-corepack .work/docker-pnpm-store

IGNORE_FILE=".work/package-vsix.vscodeignore"
USE_GENERATED_IGNORE=true
for arg in "$@"; do
	case "$arg" in
		--ignoreFile|--ignoreFile=*)
			USE_GENERATED_IGNORE=false
			;;
	esac
done

if [[ "$USE_GENERATED_IGNORE" == true ]]; then
	{
		cat .vscodeignore
		printf '\n# Local packaging artifacts\n'
		printf '.augment\n.augment/**\n'
		printf '.codex\n.codex/**\n'
		printf '.superpowers\n.superpowers/**\n'
		printf '.tasks\n.tasks/**\n'
		printf '.work\n.work/**\n'
		printf '*.vsix\n'
	} >"$IGNORE_FILE"
fi

docker_args=(
	--rm
	--interactive
	--pull "$DOCKER_PULL"
	--user "$(id -u):$(id -g)"
	--env "HOME=/tmp"
	--env "CI=true"
	--env "COREPACK_HOME=/workspace/.work/docker-corepack"
	--env "COREPACK_NPM_REGISTRY=$COREPACK_NPM_REGISTRY"
	--env "PACKAGE_VSIX_IGNORE_FILE=$IGNORE_FILE"
	--env "PACKAGE_VSIX_USE_GENERATED_IGNORE=$USE_GENERATED_IGNORE"
	--volume "$ROOT:/workspace"
	--workdir /workspace
)

if [[ -n "$DOCKER_PLATFORM" ]]; then
	docker_args+=(--platform "$DOCKER_PLATFORM")
fi

log "Packaging in Docker image: $NODE_IMAGE"
log "npm registry: $PRIMARY_NPM_REGISTRY"
log "fallback npm registry: $FALLBACK_NPM_REGISTRY"

docker run "${docker_args[@]}" "$NODE_IMAGE" bash -s -- \
	"$PNPM_VERSION" \
	"$PRIMARY_NPM_REGISTRY" \
	"$FALLBACK_NPM_REGISTRY" \
	"$@" <<'CONTAINER_SCRIPT'
set -Eeuo pipefail

PNPM_VERSION="$1"
PRIMARY_NPM_REGISTRY="$2"
FALLBACK_NPM_REGISTRY="$3"
shift 3

export PATH="/workspace/.work/docker-bin:$PATH"

echo "[package-vsix:docker] Node: $(node -v)"
echo "[package-vsix:docker] Preparing pnpm@$PNPM_VERSION"
corepack enable --install-directory /workspace/.work/docker-bin
corepack prepare "pnpm@$PNPM_VERSION" --activate
pnpm config set store-dir /workspace/.work/docker-pnpm-store
pnpm config set confirmModulesPurge false
echo "[package-vsix:docker] pnpm: $(pnpm -v)"

echo "[package-vsix:docker] Installing dependencies with $PRIMARY_NPM_REGISTRY"
if ! pnpm install --frozen-lockfile --registry="$PRIMARY_NPM_REGISTRY"; then
	if [[ "$PRIMARY_NPM_REGISTRY" == "$FALLBACK_NPM_REGISTRY" ]]; then
		echo "[package-vsix:docker] Dependency install failed with $PRIMARY_NPM_REGISTRY" >&2
		exit 1
	fi

	echo "[package-vsix:docker] Primary registry failed; retrying with $FALLBACK_NPM_REGISTRY"
	pnpm install --frozen-lockfile --registry="$FALLBACK_NPM_REGISTRY"
fi

echo "[package-vsix:docker] Packaging GitLens VSIX"
ignore_args=()
if [[ "${PACKAGE_VSIX_USE_GENERATED_IGNORE:-false}" == true ]]; then
	ignore_args=(--ignoreFile "$PACKAGE_VSIX_IGNORE_FILE")
fi

pnpm exec vsce package \
	--no-dependencies \
	"${ignore_args[@]}" \
	--allow-package-all-secrets \
	--allow-package-env-file \
	"$@"
CONTAINER_SCRIPT

log "Generated packages:"
ls -lh ./*.vsix
