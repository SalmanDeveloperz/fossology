#!/bin/bash
# Bring up the FOSSology Kubernetes PoC on a local kind cluster.
# SPDX-FileCopyrightText: © 2026 Muhammad Salman
#
# SPDX-License-Identifier: GPL-2.0-only
#
# Prerequisite: the stock image, e.g. `docker compose build` at the repo root
# (produces fossology:latest). Override with BASE_IMAGE=...

set -o errexit -o nounset -o pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
CLUSTER="${CLUSTER:-fossology-dev}"
BASE_IMAGE="${BASE_IMAGE:-fossology:latest}"
IMAGE="fossology-k8s:poc"
NS="fossology"

# fossinit.php records the DB Release only when the build has a version; an
# empty one makes every scheduler restart replay legacy migrations and abort.
# The version comes from `git describe --tags`, so tag-less clones break it.
base_version="$(docker run --rm --entrypoint sh "$BASE_IMAGE" -c \
  "sed -n 's/^VERSION=\"\(.*\)\"$/\1/p' /usr/local/etc/fossology/VERSION")"
if [[ -z "$base_version" ]]; then
  echo "ERROR: $BASE_IMAGE was built without a version. Fix with:" >&2
  echo "  git fetch --tags https://github.com/fossology/fossology.git" >&2
  echo "  docker compose build" >&2
  exit 1
fi
echo "Base image $BASE_IMAGE is FOSSology $base_version"

if ! kind get clusters 2>/dev/null | grep -qx "$CLUSTER"; then
  kind create cluster --name "$CLUSTER" --config "$HERE/kind-config.yaml"
fi
kubectl config use-context "kind-$CLUSTER"

docker build --build-arg BASE_IMAGE="$BASE_IMAGE" -t "$IMAGE" "$HERE"
kind load docker-image "$IMAGE" --name "$CLUSTER"

kubectl apply -f "$HERE/manifests/00-namespace.yaml"

# The private key only ever exists in a throwaway dir and in the Secret.
if ! kubectl -n "$NS" get secret fossology-ssh >/dev/null 2>&1; then
  keydir="$(mktemp -d)"
  trap 'rm -rf "$keydir"' EXIT
  ssh-keygen -q -t ed25519 -N '' -C fossology-scheduler -f "$keydir/id_ed25519"
  (cd "$keydir" && kubectl -n "$NS" create secret generic fossology-ssh \
    --from-file=id_ed25519=id_ed25519 \
    --from-file=authorized_keys=id_ed25519.pub)
fi

kubectl apply -f "$HERE/manifests"
# The image tag is fixed, so pick up a rebuilt image explicitly.
kubectl -n "$NS" rollout restart deployment fossology-worker fossology-scheduler fossology-web

kubectl -n "$NS" rollout status statefulset/fossology-db --timeout=300s
kubectl -n "$NS" rollout status deployment/fossology-worker --timeout=300s
kubectl -n "$NS" rollout status deployment/fossology-scheduler --timeout=600s
kubectl -n "$NS" rollout status deployment/fossology-web --timeout=600s

echo
echo "FOSSology UI: http://localhost:8082/repo  (user fossy / password fossy)"
