#!/usr/bin/env bash
# Build the stack's images on THIS machine (fast, native), push them to your
# private GHCR, and have the server pull them and restart. Used by the "Deploy"
# workflow when a commit message contains [self-hosted], and runnable by hand:
#
#   DEPLOY_HOST=1.2.3.4 DEPLOY_USER=ubuntu GHCR_USER=you GHCR_TOKEN=<token with write:packages> ./deploy/ship.sh
#
# Needs: Docker (running), ssh access to the server (a key in the agent or
# SSH_CONFIG pointing at one), and on the server Docker Compose >= 2.24 and the
# repo already uploaded to DEPLOY_PATH (the workflow rsyncs it first).
#
# Settings stay on the server; nothing sensitive is stored in GitHub.
#
#   BUILD_ONLY=1 ./deploy/ship.sh     build everything locally, push and deploy nothing
set -euo pipefail
cd "$(dirname "$0")/.."

DEPLOY_PATH="${DEPLOY_PATH:-/opt/aseman}"
SSH=(ssh ${SSH_CONFIG:+-F "$SSH_CONFIG"} -o BatchMode=yes "${DEPLOY_USER:-ubuntu}@${DEPLOY_HOST:-deploy}")
[ -n "${SSH_TARGET:-}" ] && SSH=(ssh ${SSH_CONFIG:+-F "$SSH_CONFIG"} -o BatchMode=yes "$SSH_TARGET")
TAG="${IMAGE_TAG:-$(git rev-parse --short=12 HEAD)}"
OWNER="$(printf '%s' "${GHCR_OWNER:-${GHCR_USER:-${GITHUB_REPOSITORY_OWNER:-}}}" | tr '[:upper:]' '[:lower:]')"
REGISTRY="ghcr.io/${OWNER}"
BUILD_ONLY="${BUILD_ONLY:-}"
if [ -z "$BUILD_ONLY" ]; then
  : "${GHCR_USER:?set GHCR_USER (your GitHub username)}" "${GHCR_TOKEN:?set GHCR_TOKEN (a token with write:packages)}"
  [ -n "$OWNER" ] || { echo "set GHCR_OWNER (or GITHUB_REPOSITORY_OWNER)" >&2; exit 1; }
fi

# Build for the server's CPU, whatever this machine is.
if [ -z "${PLATFORM:-}" ]; then
  if [ -n "$BUILD_ONLY" ]; then arch="$(uname -m)"; else arch="$("${SSH[@]}" uname -m)"; fi
  case "$arch" in aarch64|arm64) PLATFORM=linux/arm64 ;; *) PLATFORM=linux/amd64 ;; esac
fi
echo "==> platform $PLATFORM, tag $TAG"

# name | build context | name the compose file uses for it on the server
IMAGES=(
  "node|./services|aseman/asemand:latest"
  "web|./app|aseman/flutter-web:latest"
  "agents|./services/plugins/adapters/vmm/harness/runtime|aseman/harness:v1"
  "sandbox|./deploy/sandbox-computer|aseman/sandbox-computer:latest"
  "tools|./deploy/tool-runtime|aseman/tool-runtime:v1"
  "db|./deploy/postgres|aseman/postgres:16-pgvector"
)

logdir="$(mktemp -d)"
pids=()
build() { # name context
  local name="$1" ctx="$2"
  local start=$SECONDS
  local args=()
  # The sandbox computer carries the tool runtime, built first.
  [ "$name" = sandbox ] && args=(--build-arg "TOOL_RUNTIME_IMAGE=$REGISTRY/aseman-prod-tools:$TAG")
  if docker build --platform "$PLATFORM" ${args[@]+"${args[@]}"} -t "$REGISTRY/aseman-prod-$name:$TAG" "$ctx" >"$logdir/$name.log" 2>&1; then
    echo "    built $name in $((SECONDS - start))s"
  else
    echo "    BUILD FAILED: $name" >&2; tail -30 "$logdir/$name.log" >&2; return 1
  fi
}
echo "==> building the tool runtime (the sandbox computer copies it)"
build tools ./deploy/tool-runtime || exit 1
echo "==> building (in parallel)"
for entry in "${IMAGES[@]}"; do
  IFS='|' read -r name ctx _ <<<"$entry"
  [ "$name" = tools ] && continue
  build "$name" "$ctx" & pids+=($!)
done
fail=0; for p in "${pids[@]}"; do wait "$p" || fail=1; done
[ "$fail" = 0 ] || exit 1
[ -z "$BUILD_ONLY" ] || { echo "==> BUILD_ONLY: done, nothing pushed"; exit 0; }

echo "==> pushing to $REGISTRY"
trap 'docker logout ghcr.io >/dev/null 2>&1 || true' EXIT
printf '%s' "$GHCR_TOKEN" | docker login ghcr.io -u "$GHCR_USER" --password-stdin >/dev/null
for entry in "${IMAGES[@]}"; do IFS='|' read -r name _ _ <<<"$entry"; docker push -q "$REGISTRY/aseman-prod-$name:$TAG" >/dev/null & done
wait

echo "==> deploying on the server"
printf '%s' "$GHCR_TOKEN" | "${SSH[@]}" "docker login ghcr.io -u '$GHCR_USER' --password-stdin >/dev/null"
pull_cmds=""
for entry in "${IMAGES[@]}"; do
  IFS='|' read -r name _ local_name <<<"$entry"
  pull_cmds+="docker pull -q '$REGISTRY/aseman-prod-$name:$TAG' >/dev/null && docker tag '$REGISTRY/aseman-prod-$name:$TAG' '$local_name'; "
done
"${SSH[@]}" bash -s <<REMOTE
set -euo pipefail
trap 'docker logout ghcr.io >/dev/null 2>&1 || true' EXIT
cd '$DEPLOY_PATH'
[ -f .env ] || { echo "Missing $DEPLOY_PATH/.env on the server. See deploy/README.md." >&2; exit 1; }
mkdir -p /tmp/aseman-nomad
$pull_cmds
# The images are already here under the names the compose file uses: nothing to build.
# Remove only service containers; keep volumes and networks.
docker compose -f docker-compose.yml -f deploy/docker-compose.prod.yml rm --stop --force
docker compose -f docker-compose.yml -f deploy/docker-compose.prod.yml up -d --no-build --remove-orphans
docker compose -f docker-compose.yml -f deploy/docker-compose.prod.yml ps
docker image prune -af --filter "until=72h" >/dev/null
REMOTE
echo "==> done ($TAG)"
