#!/bin/bash
# Build the image and install the FOSSology Helm chart on a local kind cluster.
# SPDX-FileCopyrightText: © 2026 Muhammad Salman
#
# SPDX-License-Identifier: GPL-2.0-only
#
# Prerequisite: the stock image, e.g. `docker compose build` at the repo root
# (produces fossology:latest). Override with BASE_IMAGE=...
# Extra arguments go to `helm upgrade --install`, e.g.
#   bash k8s/scripts/up.sh --set workers.replicas=2

set -o errexit -o nounset -o pipefail

K8S_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CLUSTER="${CLUSTER:-fossology-dev}"
BASE_IMAGE="${BASE_IMAGE:-fossology:latest}"
REPOSITORY="fossology-k8s"
NS="${NS:-fossology}"
RELEASE="${RELEASE:-fossology}"

# fossinit.php records the DB Release only when the build has a version; an
# empty one makes every later migration replay legacy steps and abort.
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
  kind create cluster --name "$CLUSTER" --config "$K8S_DIR/kind/kind-config.yaml"
fi
kubectl config use-context "kind-$CLUSTER"

# Tag by build inputs, not by image ID: BuildKit provenance gives every
# rebuild a new ID, which would roll every pod and re-run the migration.
tag="dev-$({ docker image inspect -f '{{.Id}}' "$BASE_IMAGE"; cat "$K8S_DIR"/image/*; } \
  | sha256sum | cut -c1-12)"
if ! docker image inspect "$REPOSITORY:$tag" >/dev/null 2>&1; then
  docker build --build-arg BASE_IMAGE="$BASE_IMAGE" -t "$REPOSITORY:$tag" "$K8S_DIR/image"
fi
# kind's own presence check misses images from Docker Desktop's containerd
# store and would re-send the multi-GB image on every run; ask each node.
for node in $(kind get nodes --name "$CLUSTER"); do
  if ! docker exec "$node" crictl inspecti "docker.io/library/$REPOSITORY:$tag" >/dev/null 2>&1; then
    kind load docker-image "$REPOSITORY:$tag" --name "$CLUSTER"
    break
  fi
done

helm upgrade --install "$RELEASE" "$K8S_DIR/charts/fossology" \
  --namespace "$NS" --create-namespace \
  -f "$K8S_DIR/kind/values-kind.yaml" \
  --set image.repository="$REPOSITORY" \
  --set image.tag="$tag" \
  --wait --timeout 20m \
  "$@"

echo
echo "FOSSology UI: http://localhost:8082/repo  (user fossy / password fossy)"
