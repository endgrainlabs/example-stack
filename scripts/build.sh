#!/usr/bin/env bash
set -euo pipefail

# Brings up the local registry, builds the service images, and pushes them to
# it. setup.sh wires that registry into the k3d cluster. This script is the
# single source of truth for the registry, the image builds, and the tags;
# setup.sh calls it rather than duplicating the logic.
#
# Proto generation needs no preinstalled toolchain: this script downloads a
# pinned protoc into ./bin/tools and builds the code generator plugins from the
# versions pinned in go.mod.
#
# Invoke with: bash scripts/build.sh

REGISTRY_PORT="5111"
REGISTRY_NAME="example-stack-registry"
REGISTRY=""
IMAGE_PREFIX="example-stack"

# Pinned by tag and digest, like every other image the stack pulls.
REGISTRY_IMAGE="docker.io/library/registry:2@sha256:a3d8aaa63ed8681a604f1dea0aa03f100d5895b6a58ace528858a7b332415373"

usage() {
    cat <<EOF
Usage: $(basename "$0") [config-flags...]

Config flags (all optional, defaults shown):
  --registry-port=PORT   5111
  --registry-name=NAME   example-stack-registry   (the registry container)
  --registry=HOST:PORT   localhost:\${REGISTRY_PORT}
  --image-prefix=NAME    example-stack   (images push as
                         \${REGISTRY}/\${IMAGE_PREFIX}/<service>:latest)
  --help                 Show this message
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --registry-port=*) REGISTRY_PORT="${1#*=}" ;;
        --registry-name=*) REGISTRY_NAME="${1#*=}" ;;
        --registry=*)      REGISTRY="${1#*=}" ;;
        --image-prefix=*)  IMAGE_PREFIX="${1#*=}" ;;
        --help|-h)         usage; exit 0 ;;
        *)                 echo "ERROR: unknown flag '$1'" >&2; echo "" >&2; usage >&2; exit 1 ;;
    esac
    shift
done

REGISTRY="${REGISTRY:-localhost:${REGISTRY_PORT}}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "${SCRIPT_DIR}")"

# --- Registry ---
#
# The push target has to exist before anything is built, and this script is
# also run on its own to rebuild against a live cluster, so it brings the
# registry up itself instead of assuming a bring-up already did.

if podman container exists "${REGISTRY_NAME}" 2>/dev/null; then
    if [ "$(podman inspect -f '{{.State.Running}}' "${REGISTRY_NAME}" 2>/dev/null)" = "true" ]; then
        echo "==> Registry '${REGISTRY_NAME}' already running"
    else
        echo "==> Starting existing registry '${REGISTRY_NAME}'"
        podman start "${REGISTRY_NAME}"
    fi
else
    echo "==> Creating local registry: ${REGISTRY_NAME}"
    podman run -d \
        --name "${REGISTRY_NAME}" \
        -p "${REGISTRY_PORT}:5000" \
        --restart always \
        "${REGISTRY_IMAGE}"
fi

# --- Proto toolchain ---
#
# The generated code is committed, so the versions that produce it are pinned:
# protoc by release archive and checksum here, the two plugins by the tool
# directives in go.mod. Whatever protoc happens to be on the developer's PATH
# is not used.

TOOLS_DIR="${REPO_ROOT}/bin/tools"
PROTOC_VERSION="34.1"
PROTOC_BASE_URL="https://github.com/protocolbuffers/protobuf/releases/download"

# Checksums as published on the protobuf release assets for v${PROTOC_VERSION}.
case "$(uname -s)/$(uname -m)" in
    Darwin/arm64)
        PROTOC_ASSET="protoc-${PROTOC_VERSION}-osx-aarch_64.zip"
        PROTOC_SHA256="2c7e92b8b578916937df132b3032e2e8e6c170862ecf7a8333094a6f3d03650c" ;;
    Darwin/x86_64)
        PROTOC_ASSET="protoc-${PROTOC_VERSION}-osx-x86_64.zip"
        PROTOC_SHA256="ab124429c1f49951f03b6c0c0e911fec04e2c7c20de5c935e0cde7353bbd016c" ;;
    Linux/x86_64)
        PROTOC_ASSET="protoc-${PROTOC_VERSION}-linux-x86_64.zip"
        PROTOC_SHA256="af27ea66cd26938fe48587804ca7d4817457a08350021a1c6e23a27ccc8c6904" ;;
    Linux/aarch64)
        PROTOC_ASSET="protoc-${PROTOC_VERSION}-linux-aarch_64.zip"
        PROTOC_SHA256="31c5e9e3c7bf013cf41fb97765ee255c140024a6b175b6cc9b64beddd7c23ba7" ;;
    *)
        echo "ERROR: no pinned protoc for $(uname -s)/$(uname -m)" >&2
        exit 1 ;;
esac

sha256_of() {
    if command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | cut -d' ' -f1
    else
        sha256sum "$1" | cut -d' ' -f1
    fi
}

PROTOC_DIR="${TOOLS_DIR}/protoc-${PROTOC_VERSION}"
PROTOC="${PROTOC_DIR}/bin/protoc"

if [ ! -x "${PROTOC}" ]; then
    echo "==> Downloading protoc ${PROTOC_VERSION}"
    mkdir -p "${TOOLS_DIR}"
    ARCHIVE="${TOOLS_DIR}/${PROTOC_ASSET}"
    curl -fsSL -o "${ARCHIVE}" "${PROTOC_BASE_URL}/v${PROTOC_VERSION}/${PROTOC_ASSET}"

    ACTUAL_SHA256="$(sha256_of "${ARCHIVE}")"
    if [ "${ACTUAL_SHA256}" != "${PROTOC_SHA256}" ]; then
        rm -f "${ARCHIVE}"
        echo "ERROR: protoc checksum mismatch for ${PROTOC_ASSET}" >&2
        echo "       expected ${PROTOC_SHA256}" >&2
        echo "       got      ${ACTUAL_SHA256}" >&2
        exit 1
    fi

    rm -rf "${PROTOC_DIR}"
    unzip -q "${ARCHIVE}" -d "${PROTOC_DIR}"
    rm -f "${ARCHIVE}"
fi

echo "==> Building the proto plugins pinned in go.mod"
(cd "${REPO_ROOT}" && go build -o "${TOOLS_DIR}/protoc-gen-go" google.golang.org/protobuf/cmd/protoc-gen-go)
(cd "${REPO_ROOT}" && go build -o "${TOOLS_DIR}/protoc-gen-go-grpc" google.golang.org/grpc/cmd/protoc-gen-go-grpc)
export PATH="${TOOLS_DIR}:${PATH}"

# --- Proto generation ---

PROTO_DIR="${REPO_ROOT}/go-grpc/proto"

echo "==> Generating proto code"
"${PROTOC}" --go_out="${PROTO_DIR}/echopb" --go_opt=paths=source_relative \
    --go-grpc_out="${PROTO_DIR}/echopb" --go-grpc_opt=paths=source_relative \
    -I "${PROTO_DIR}" \
    "${PROTO_DIR}/echo.proto"

"${PROTOC}" --go_out="${PROTO_DIR}/pricingpb" --go_opt=paths=source_relative \
    --go-grpc_out="${PROTO_DIR}/pricingpb" --go-grpc_opt=paths=source_relative \
    -I "${PROTO_DIR}" \
    "${PROTO_DIR}/pricing.proto"

# --- Image builds ---

for img in \
    "migrate|migrate/Dockerfile" \
    "go-api|go-api/Dockerfile" \
    "go-grpc|go-grpc/Dockerfile" \
    "rust-inventory|rust-inventory/Dockerfile"; do

    name="${img%%|*}"
    dockerfile="${img##*|}"
    tag="${REGISTRY}/${IMAGE_PREFIX}/${name}:latest"

    echo "==> Building '${name}'"
    podman build -t "${tag}" -f "${REPO_ROOT}/${dockerfile}" "${REPO_ROOT}"

    echo "==> Pushing '${name}' to ${REGISTRY}"
    podman push "${tag}" --tls-verify=false
done

echo "==> Done"
