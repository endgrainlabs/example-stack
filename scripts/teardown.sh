#!/usr/bin/env bash
set -euo pipefail

# Tears down the example stack: k3d cluster, local registry, the podman
# network, and the cluster's kubeconfig file. Locally built images are kept by
# default so the next bring-up skips the rebuild; --remove-images deletes them
# too.
#
# All configuration is by flag. Deleting the wrong cluster is destructive and
# irreversible, and a stray export in a shell could silently redirect this.
# Flags do not propagate.
#
# Invoke with: bash scripts/teardown.sh

REMOVE_IMAGES=0
CLUSTER_NAME="example-stack"
REGISTRY_NAME="example-stack-registry"
REGISTRY_PORT="5111"
IMAGE_PREFIX="example-stack"
KUBECONFIG_PATH="${HOME}/.kube/example-stack.yaml"

usage() {
    cat <<EOF
Usage: $(basename "$0") [config-flags...] [--remove-images]

Config flags (all optional, defaults shown):
  --cluster-name=NAME       example-stack
  --registry-name=NAME      example-stack-registry
  --registry-port=PORT      5111
  --image-prefix=NAME       example-stack
  --kubeconfig-path=PATH    \$HOME/.kube/example-stack.yaml
  --remove-images           Also delete the locally built images
  --help                    Show this message
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --remove-images)     REMOVE_IMAGES=1 ;;
        --cluster-name=*)    CLUSTER_NAME="${1#*=}" ;;
        --registry-name=*)   REGISTRY_NAME="${1#*=}" ;;
        --registry-port=*)   REGISTRY_PORT="${1#*=}" ;;
        --image-prefix=*)    IMAGE_PREFIX="${1#*=}" ;;
        --kubeconfig-path=*) KUBECONFIG_PATH="${1#*=}" ;;
        --help|-h)           usage; exit 0 ;;
        *)                   echo "ERROR: unknown flag '$1'" >&2; echo "" >&2; usage >&2; exit 1 ;;
    esac
    shift
done

REGISTRY="localhost:${REGISTRY_PORT}"
NETWORK_NAME="k3d-${CLUSTER_NAME}"

echo "==> Teardown config:"
echo "    cluster-name:      ${CLUSTER_NAME}"
echo "    registry-name:     ${REGISTRY_NAME}"
echo "    registry-port:     ${REGISTRY_PORT}"
echo "    network-name:      ${NETWORK_NAME}"
echo "    kubeconfig-path:   ${KUBECONFIG_PATH}"
echo "    remove-images:     $([ "${REMOVE_IMAGES}" -eq 1 ] && echo yes || echo no)"

# Remove the registry container before deleting the cluster so k3d cleans its
# own network in one shot; otherwise k3d warns that the network still has
# attached containers. -v also drops the registry's anonymous data volume.
# Without it every setup and teardown cycle orphans one, which accumulates into
# tens of gigabytes of dangling volumes. -v removes only the container's own
# anonymous volume, never a named or shared one.
if podman container exists "${REGISTRY_NAME}" 2>/dev/null; then
    echo "==> Removing registry container: ${REGISTRY_NAME}"
    podman rm -f -v "${REGISTRY_NAME}"
else
    echo "==> Registry container '${REGISTRY_NAME}' does not exist"
fi

if k3d cluster list -o json 2>/dev/null | grep -q "\"name\":\"${CLUSTER_NAME}\""; then
    echo "==> Deleting k3d cluster: ${CLUSTER_NAME}"
    k3d cluster delete "${CLUSTER_NAME}"
else
    echo "==> Cluster '${CLUSTER_NAME}' does not exist"
fi

# k3d usually deletes the network once no containers are attached. If it did
# not, or if the cluster never existed, remove it here.
if podman network exists "${NETWORK_NAME}" 2>/dev/null; then
    echo "==> Removing podman network: ${NETWORK_NAME}"
    podman network rm -f "${NETWORK_NAME}" || true
else
    echo "==> Network '${NETWORK_NAME}' does not exist"
fi

# The cluster owns this file exclusively, so it goes with the cluster.
if [ -f "${KUBECONFIG_PATH}" ]; then
    echo "==> Removing kubeconfig: ${KUBECONFIG_PATH}"
    rm -f "${KUBECONFIG_PATH}"
else
    echo "==> Kubeconfig '${KUBECONFIG_PATH}' does not exist"
fi

if [ "${REMOVE_IMAGES}" -eq 1 ]; then
    echo "==> Removing built images"
    for name in migrate go-api go-grpc rust-inventory; do
        tag="${REGISTRY}/${IMAGE_PREFIX}/${name}:latest"
        if podman image exists "${tag}" 2>/dev/null; then
            echo "    Removing ${tag}"
            podman rmi -f "${tag}" || true
        fi
    done
else
    echo "==> Keeping built images (pass --remove-images to delete them)"
fi

echo "==> Done"
