#!/usr/bin/env bash
set -euo pipefail

# Brings up the example stack: local registry, k3d cluster, images, an
# in-cluster Forgejo holding the manifests, Flux reconciling from it, the
# monitoring stack, the services, a seeded Flagsmith, and a smoke test. The
# Forgejo and Flagsmith access tokens it mints are left behind in the
# forgejo-bootstrap and flagsmith-bootstrap Secrets, and the key the Flagsmith
# dashboard reads its own feature flags with in the flagsmith-dashboard Secret.
#
# Phases are ordered so a failure costs as little as possible. The registry and
# the image builds run before any cluster exists, so a broken build never
# leaves a cluster behind. Every phase checks for the state it would create, so
# re-running the script against a live cluster reconciles instead of starting
# over.
#
#   A. Builds       local registry up, service images built and pushed
#   B. Cluster      k3d cluster created and wired to the registry
#   C. Deploy       Forgejo, Flux, monitoring, services, Flagsmith
#   D. Smoke        smoke test against the running services
#
# Invoke with: bash scripts/setup.sh

# --- Defaults ---
#
# The stack uses non-default host ports so it can run beside whatever else is
# on the machine. Every one of them is a flag.

CLUSTER_NAME="example-stack"
# Fixed, not a flag: every manifest in k8s/apps/base names this namespace.
NAMESPACE="example-stack"
REGISTRY_NAME="example-stack-registry"
REGISTRY_PORT="5111"
INGRESS_PORT="8090"
K8S_API_PORT="6551"
# Empty until the flags are parsed: the default follows the cluster name, so
# --cluster-name alone gives that cluster its own kubeconfig file.
KUBECONFIG_PATH=""
FORGEJO_PASSWORD="password"
# Flagsmith runs Django's password validators on signup, so the demo value
# has to be long enough and not a common word.
FLAGSMITH_PASSWORD="example-stack-demo"

usage() {
    cat <<EOF
Usage: $(basename "$0") [config-flags...]

Config flags (all optional, defaults shown):
  --cluster-name=NAME       example-stack
  --registry-name=NAME      example-stack-registry
  --registry-port=PORT      5111
  --ingress-port=PORT       8090   (host port for HTTP through Traefik)
  --k8s-api-port=PORT       6551   (host port for the Kubernetes API)
  --kubeconfig-path=PATH    \$HOME/.kube/<cluster-name>.yaml
  --forgejo-password=PASS   password   (password for the Forgejo bootstrap
                            user, demo-only and visible in the process list
                            while setup runs)
  --flagsmith-password=PASS example-stack-demo   (password for the Flagsmith
                            bootstrap user, demo-only and visible in the
                            process list while setup runs; Flagsmith rejects
                            a short or common one)
  --help                    Show this message
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --cluster-name=*)       CLUSTER_NAME="${1#*=}" ;;
        --registry-name=*)      REGISTRY_NAME="${1#*=}" ;;
        --registry-port=*)      REGISTRY_PORT="${1#*=}" ;;
        --ingress-port=*)       INGRESS_PORT="${1#*=}" ;;
        --k8s-api-port=*)       K8S_API_PORT="${1#*=}" ;;
        --kubeconfig-path=*)    KUBECONFIG_PATH="${1#*=}" ;;
        --forgejo-password=*)   FORGEJO_PASSWORD="${1#*=}" ;;
        --flagsmith-password=*) FLAGSMITH_PASSWORD="${1#*=}" ;;
        --help|-h)              usage; exit 0 ;;
        *)                      echo "ERROR: unknown flag '$1'" >&2; echo "" >&2; usage >&2; exit 1 ;;
    esac
    shift
done

KUBECONFIG_PATH="${KUBECONFIG_PATH:-${HOME}/.kube/${CLUSTER_NAME}.yaml}"

REGISTRY="localhost:${REGISTRY_PORT}"
FLUX_VERSION="v2.8.5"
FORGEJO_NS="forgejo"
FORGEJO_ORG="endgrainlabs"
FORGEJO_REPO="example-stack"
FORGEJO_ADMIN_USER="bootstrap"
# Synthetic address for the demo-only bootstrap account. Nothing sends mail.
FORGEJO_ADMIN_EMAIL="bootstrap@forgejo.local"
# Local port for the bootstrap port-forward: a port unlikely to be in use on
# the host.
FORGEJO_PF_PORT="13000"
MONITORING_NS="monitoring"
FLAGSMITH_NS="flagsmith"
FLAGSMITH_ORG="example-stack"
FLAGSMITH_PROJECT="example-stack"
# The project the Flagsmith dashboard reads its own feature flags from, and
# the one environment in it whose client-side key the dashboard is given.
FLAGSMITH_DASHBOARD_PROJECT="flagsmith-dashboard"
FLAGSMITH_DASHBOARD_ENV="dashboard"
# Synthetic address for the demo-only bootstrap account. Nothing sends mail.
FLAGSMITH_ADMIN_EMAIL="bootstrap@flagsmith.local"
# Local port for the bootstrap port-forward: a port unlikely to be in use on
# the host.
FLAGSMITH_PF_PORT="18000"
# kube-prometheus-stack, PostgreSQL, and two node containers do not fit in
# less than this.
MIN_MACHINE_MEMORY_MIB="4096"

# Upstream image the bring-up pulls directly, pinned by tag and digest. The
# rest of the pinned set lives in the manifests and Dockerfiles that use it,
# and the registry image in build.sh.
K3S_IMAGE="docker.io/rancher/k3s:v1.34.11-k3s1@sha256:5d52389a0f4fd7ebdb5a1fb2d7c67c35da966230782c4abb0667d86bcccea9c2"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "${SCRIPT_DIR}")"

# The cluster gets its own kubeconfig file, so it never rewrites the default
# one and never changes the context the shell already had.
export KUBECONFIG="${KUBECONFIG_PATH}"

echo "==> Bring-up config:"
echo "    cluster-name:      ${CLUSTER_NAME}"
echo "    namespace:         ${NAMESPACE}"
echo "    registry:          ${REGISTRY_NAME} (host port ${REGISTRY_PORT})"
echo "    ingress port:      ${INGRESS_PORT} (HTTP)"
echo "    kubernetes api:    ${K8S_API_PORT}"
echo "    kubeconfig:        ${KUBECONFIG_PATH}"

# --- Cleanup tracking ---

FORGEJO_PF_PID=""
FLAGSMITH_PF_PID=""
WORK_DIR=""

cleanup() {
    if [ -n "${FORGEJO_PF_PID}" ]; then
        kill "${FORGEJO_PF_PID}" 2>/dev/null || true
        wait "${FORGEJO_PF_PID}" 2>/dev/null || true
    fi
    if [ -n "${FLAGSMITH_PF_PID}" ]; then
        kill "${FLAGSMITH_PF_PID}" 2>/dev/null || true
        wait "${FLAGSMITH_PF_PID}" 2>/dev/null || true
    fi
    if [ -n "${WORK_DIR}" ] && [ -d "${WORK_DIR}" ]; then
        rm -rf "${WORK_DIR}"
    fi
}
trap cleanup EXIT

# --- Helpers ---

forgejo_exec() {
    kubectl -n "${FORGEJO_NS}" exec deploy/forgejo -- "$@"
}

# One Python program answers every question the Flagsmith seed asks of a
# Flagsmith API response. The response arrives as a string, so it is piped
# back in, the way prom_fact does it in validate-stack.sh. A regular
# expression over JSON would break the first time a field moved.
#
#   field KEY        one key of an object
#   find NAME KEY    one key of the first list entry whose name is NAME
#   names            the name of every list entry, one per line
#
# A list answer is either a bare array or a paginated object with "results".
# Nothing found is a non-zero exit, so callers fall back with || echo "".
flagsmith_fact() {
    local response="$1"
    shift
    printf '%s' "${response}" | python3 -c '
import json
import sys

mode = sys.argv[1]
try:
    doc = json.load(sys.stdin)
except ValueError:
    sys.exit(1)

if mode == "field":
    value = doc.get(sys.argv[2]) if isinstance(doc, dict) else None
    if value is None:
        sys.exit(1)
    print(value)
    sys.exit(0)

items = doc.get("results", []) if isinstance(doc, dict) else doc
if mode == "names":
    for item in items:
        print(item["name"])
    sys.exit(0)

for item in items:
    if item["name"] == sys.argv[2]:
        print(item[sys.argv[3]])
        sys.exit(0)
sys.exit(1)
' "$@" 2>/dev/null
}

# Writes one bootstrap Secret, into the services' namespace unless a leading
# -n names another. These values are minted while the stack comes up, so they
# cannot live in the manifests Flux reconciles; Flux prunes only what it
# applied, so a Secret written here survives every reconcile. The label says
# which script owns it.
write_bootstrap_secret() {
    local ns="${NAMESPACE}"
    if [ "$1" = "-n" ]; then
        ns="$2"
        shift 2
    fi
    local name="$1"
    local app="$2"
    shift 2
    local literal
    local args
    args=()
    for literal in "$@"; do
        args+=(--from-literal="${literal}")
    done
    kubectl -n "${ns}" create secret generic "${name}" \
        "${args[@]}" --dry-run=client -o yaml \
        | kubectl -n "${ns}" apply -f - > /dev/null
    kubectl -n "${ns}" label secret "${name}" --overwrite \
        "app=${app}" "app.kubernetes.io/managed-by=setup.sh" > /dev/null
}

# A call to the Flagsmith API with the bootstrap token attached. The token and
# the base URL are set in phase C9, before the first call.
flagsmith_api() {
    local method="$1"
    local path="$2"
    local body="${3:-}"
    if [ -n "${body}" ]; then
        curl -s -X "${method}" \
            -H "Authorization: Token ${FLAGSMITH_TOKEN}" \
            -H "Content-Type: application/json" \
            -d "${body}" \
            "${FLAGSMITH_API}${path}" || echo ""
    else
        curl -s -X "${method}" \
            -H "Authorization: Token ${FLAGSMITH_TOKEN}" \
            "${FLAGSMITH_API}${path}" || echo ""
    fi
}

# A node container that has been stopped and started comes back on a different
# address in the podman network, but k3s keeps the address it first registered
# in the node's flannel annotation. The node then reports Ready and shuts its
# networking down a minute later, with "failed to find interface with
# specified node ip", and every pod on it stays Pending. Restarting the
# container again only moves the address once more; deleting the Node object
# is what makes k3s re-register with the current one. k3d names the container
# after the node.
wait_nodes_ready() {
    local node actual recorded
    kubectl wait --for=condition=Ready node --all --timeout=180s || true

    for node in $(kubectl get nodes -o name 2>/dev/null | sed 's|^node/||'); do
        actual=$(podman inspect "${node}" \
            --format '{{range $n, $v := .NetworkSettings.Networks}}{{$v.IPAddress}}{{end}}' \
            2>/dev/null || echo "")
        recorded=$(kubectl get node "${node}" \
            -o jsonpath='{.metadata.annotations.flannel\.alpha\.coreos\.com/public-ip}' \
            2>/dev/null || echo "")
        if [ -n "${actual}" ] && [ -n "${recorded}" ] && [ "${actual}" != "${recorded}" ]; then
            echo "==> Node ${node} registered ${recorded} but is now at ${actual}, re-registering it"
            kubectl delete node "${node}" > /dev/null
            podman restart "${node}" > /dev/null
        fi
    done

    kubectl wait --for=condition=Ready node --all --timeout=180s
}

# One line per key step with elapsed time, so a cold run and a warm run are a
# diff of two logs rather than a stopwatch exercise.
SETUP_START=$(date +%s)
mark() {
    local now elapsed
    now=$(date +%s)
    elapsed=$((now - SETUP_START))
    printf '    [t+%dm%02ds] %s\n' $((elapsed / 60)) $((elapsed % 60)) "$1"
}

# --- Preflight ---
#
# Everything below needs these. Checking first costs a couple of seconds;
# finding out in phase C costs a half-built cluster.

# k3d drives the container engine through the Docker API socket. podman
# serves one, but on a fresh install nothing points k3d at it, and the
# failure would otherwise surface at cluster creation, after the images
# are built.
check_engine_socket() {
    if k3d node list >/dev/null 2>&1; then
        echo "    k3d reaches the container engine"
        return 0
    fi
    echo "ERROR: k3d cannot reach the container engine through the Docker API socket" >&2
    echo "       Point it at podman's socket:" >&2
    echo "         macOS:  export DOCKER_HOST=unix://\$(podman machine inspect --format '{{.ConnectionInfo.PodmanSocket.Path}}')" >&2
    echo "                 or run 'sudo podman-mac-helper install' once, which links /var/run/docker.sock to it" >&2
    echo "         Linux:  systemctl --user enable --now podman.socket" >&2
    echo "                 export DOCKER_HOST=unix://\${XDG_RUNTIME_DIR}/podman/podman.sock" >&2
    exit 1
}

preflight() {
    local missing="" cmd state memory
    for cmd in podman k3d kubectl go curl git python3 unzip; do
        command -v "${cmd}" >/dev/null 2>&1 || missing="${missing} ${cmd}"
    done
    if [ -n "${missing}" ]; then
        echo "ERROR: required command not found:${missing}" >&2
        exit 1
    fi
    echo "    Required commands present"

    # podman on Linux runs containers directly, with no virtual machine to
    # check, and reports no machine here. Where there is one, it has to be
    # running and large enough before the first image build.
    state=$(podman machine inspect --format '{{.State}}' 2>/dev/null | head -1 || true)
    if [ -z "${state}" ]; then
        echo "    No podman machine configured, podman runs containers directly"
        check_engine_socket
        return 0
    fi
    if [ "${state}" != "running" ]; then
        echo "ERROR: the podman machine is ${state}; start it with 'podman machine start'" >&2
        exit 1
    fi
    check_engine_socket

    memory=$(podman machine inspect --format '{{.Resources.Memory}}' 2>/dev/null | head -1 || true)
    case "${memory}" in
        ''|*[!0-9]*) memory=0 ;;
    esac
    if [ "${memory}" -lt "${MIN_MACHINE_MEMORY_MIB}" ]; then
        echo "ERROR: the podman machine has ${memory} MiB of memory, and the stack needs ${MIN_MACHINE_MEMORY_MIB} MiB" >&2
        echo "       Stop it and resize it: podman machine stop && podman machine set --memory ${MIN_MACHINE_MEMORY_MIB}" >&2
        exit 1
    fi
    echo "    podman machine running with ${memory} MiB of memory"
}

echo ""
echo "==> Preflight"
preflight

echo ""
echo "=== Started: $(date '+%Y-%m-%d %H:%M:%S') ==="

# =============================================================================
# Phase A: Builds
# =============================================================================
#
# build.sh brings the registry up as well, so the push target and the images
# are one step that either succeeds or fails before a cluster exists.

echo ""
echo "=== Phase A: Builds ==="
mark "Phase A begin"

bash "${SCRIPT_DIR}/build.sh" \
    --registry-port="${REGISTRY_PORT}" \
    --registry-name="${REGISTRY_NAME}" \
    --registry="${REGISTRY}"

# =============================================================================
# Phase B: Cluster
# =============================================================================

echo ""
echo "=== Phase B: Cluster ==="
mark "Phase B begin"

if k3d cluster list -o json | grep -q "\"name\":\"${CLUSTER_NAME}\""; then
    if [ "$(podman inspect -f '{{.State.Running}}' "k3d-${CLUSTER_NAME}-server-0" 2>/dev/null)" = "true" ]; then
        echo "==> Cluster '${CLUSTER_NAME}' already running"
    else
        echo "==> Starting existing cluster '${CLUSTER_NAME}'"
        k3d cluster start "${CLUSTER_NAME}"
    fi
else
    echo "==> Creating k3d cluster: ${CLUSTER_NAME}"

    # containerd reads registries.yaml once, at node start, so the mirror is
    # handed to k3d at creation. Writing the file into running nodes instead
    # would need a cluster restart, and a restarted k3s agent can fail to
    # match the node address it recorded ("failed to find interface with
    # specified node ip") and shut its networking down.
    REGISTRIES_YAML="$(mktemp)"
    cat > "${REGISTRIES_YAML}" <<YAML
mirrors:
  "${REGISTRY_NAME}:5000":
    endpoint:
      - "http://${REGISTRY_NAME}:5000"
YAML

    # --kubeconfig-update-default=false: the default kubeconfig is left alone,
    # so this cluster never becomes the shell's current context.
    # Both host ports are bound to loopback. Without an address, the podman
    # machine's forwarder binds every interface of the host, which put the
    # whole stack on whatever network the machine was on.
    k3d cluster create "${CLUSTER_NAME}" \
        --image "${K3S_IMAGE}" \
        --agents 1 \
        --api-port "127.0.0.1:${K8S_API_PORT}" \
        --port "127.0.0.1:${INGRESS_PORT}:80@loadbalancer" \
        --registry-config "${REGISTRIES_YAML}" \
        --kubeconfig-update-default=false \
        --kubeconfig-switch-context=false \
        --wait

    rm -f "${REGISTRIES_YAML}"

    mkdir -p "$(dirname "${KUBECONFIG_PATH}")"
    k3d kubeconfig get "${CLUSTER_NAME}" > "${KUBECONFIG_PATH}"

    cat <<YAML | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: local-registry-hosting
  namespace: kube-public
data:
  localRegistryHosting.v1: |
    host: "${REGISTRY}"
    hostFromContainerRuntime: "${REGISTRY_NAME}:5000"
    help: "https://k3d.io/usage/registries/"
YAML
fi

# The kubeconfig is rewritten on every run: a stopped and restarted cluster
# keeps its host ports, but the file may be missing after a manual delete.
mkdir -p "$(dirname "${KUBECONFIG_PATH}")"
k3d kubeconfig get "${CLUSTER_NAME}" > "${KUBECONFIG_PATH}"

# k3d cluster stop disconnects non-k3d containers, so the registry must be
# re-attached after every start, whether this script created the cluster or a
# prior `k3d cluster stop` left it stopped.
if podman inspect "${REGISTRY_NAME}" \
        --format '{{range $net, $_ := .NetworkSettings.Networks}}{{$net}}{{"\n"}}{{end}}' 2>/dev/null \
        | grep -qx "k3d-${CLUSTER_NAME}"; then
    echo "==> Registry '${REGISTRY_NAME}' already connected to k3d-${CLUSTER_NAME} network"
else
    echo "==> Connecting registry '${REGISTRY_NAME}' to k3d-${CLUSTER_NAME} network"
    podman network connect "k3d-${CLUSTER_NAME}" "${REGISTRY_NAME}"
fi

echo "==> Waiting for nodes to be ready"
wait_nodes_ready

# =============================================================================
# Phase C: Deploy
# =============================================================================

echo ""
echo "=== Phase C: Deploy ==="
mark "Phase C begin"

# --- C1: Deploy Forgejo ---

echo "==> Deploying Forgejo"
kubectl apply -k "${REPO_ROOT}/k8s/infra/forgejo"
# The manifest's ROOT_URL carries the default ingress port so that Forgejo's
# redirects and clone URLs point at the host. Like the landing page and UI
# links, it follows --ingress-port.
if [ "${INGRESS_PORT}" != "8090" ]; then
    kubectl -n "${FORGEJO_NS}" set env deployment/forgejo \
        "FORGEJO__server__ROOT_URL=http://forgejo.localhost:${INGRESS_PORT}/"
fi

echo "==> Waiting for Forgejo rollout"
kubectl -n "${FORGEJO_NS}" rollout status deployment/forgejo --timeout=180s

echo "==> Waiting for Forgejo CLI to be responsive"
for _ in $(seq 1 30); do
    if forgejo_exec forgejo admin user list &>/dev/null; then
        break
    fi
    sleep 3
done

# --- C2: Bootstrap the Forgejo admin user and an access token ---
#
# The bootstrap user is created with, or reset to, FORGEJO_PASSWORD, so the
# Forgejo web interface is reachable with a known login on every machine.

echo "==> Bootstrapping Forgejo admin user"
if forgejo_exec forgejo admin user list 2>/dev/null | awk 'NR>1 {print $2}' | grep -qx "${FORGEJO_ADMIN_USER}"; then
    echo "    Admin user '${FORGEJO_ADMIN_USER}' already exists"
    forgejo_exec forgejo admin user change-password \
        --username "${FORGEJO_ADMIN_USER}" \
        --password "${FORGEJO_PASSWORD}" \
        --must-change-password=false
    echo "    Admin password reset"
else
    forgejo_exec forgejo admin user create \
        --username "${FORGEJO_ADMIN_USER}" \
        --password "${FORGEJO_PASSWORD}" \
        --email "${FORGEJO_ADMIN_EMAIL}" \
        --admin \
        --must-change-password=false
    echo "    Admin user created"
fi

echo "==> Generating Forgejo access token"
TOKEN_NAME="bootstrap-$(date +%s)"
TOKEN_OUTPUT=$(forgejo_exec forgejo admin user generate-access-token \
    --username "${FORGEJO_ADMIN_USER}" \
    --scopes all \
    --token-name "${TOKEN_NAME}" 2>&1)
FORGEJO_TOKEN=$(echo "${TOKEN_OUTPUT}" | grep -oE '[a-f0-9]{30,}' | head -1)

if [ -z "${FORGEJO_TOKEN}" ]; then
    echo "ERROR: Failed to parse access token from forgejo output:"
    echo "${TOKEN_OUTPUT}"
    exit 1
fi

# --- C3: Port-forward, create the organization and repository, seed content ---

echo "==> Port-forwarding Forgejo for bootstrap"
kubectl -n "${FORGEJO_NS}" port-forward "svc/forgejo" "${FORGEJO_PF_PORT}:3000" &>/dev/null &
FORGEJO_PF_PID=$!
# The forward answers within a second on an idle machine and several on a
# busy one, so it is polled rather than waited for by a fixed sleep. A forward
# that never answers fails here, with the cause named, rather than at the
# first API call under set -e.
for _ in $(seq 1 40); do
    if curl -s -o /dev/null --max-time 1 "http://localhost:${FORGEJO_PF_PORT}/" 2>/dev/null; then
        break
    fi
    sleep 0.5
done
if ! curl -s -o /dev/null --max-time 1 "http://localhost:${FORGEJO_PF_PORT}/" 2>/dev/null; then
    echo "ERROR: the Forgejo port-forward on localhost:${FORGEJO_PF_PORT} did not answer within 20s" >&2
    exit 1
fi

FORGEJO_API="http://localhost:${FORGEJO_PF_PORT}/api/v1"

echo "==> Ensuring the Forgejo organization and repository exist"
# A 422 means the organization already exists; ignore a non-success quietly.
curl -s -o /dev/null \
    -X POST \
    -H "Authorization: token ${FORGEJO_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{\"username\":\"${FORGEJO_ORG}\"}" \
    "${FORGEJO_API}/orgs" || true

REPO_STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
    -H "Authorization: token ${FORGEJO_TOKEN}" \
    "${FORGEJO_API}/repos/${FORGEJO_ORG}/${FORGEJO_REPO}" || echo "0")

if [ "${REPO_STATUS}" != "200" ]; then
    echo "    Creating repository ${FORGEJO_ORG}/${FORGEJO_REPO}"
    curl -sf -X POST \
        -H "Authorization: token ${FORGEJO_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "{\"name\":\"${FORGEJO_REPO}\",\"default_branch\":\"main\",\"auto_init\":false,\"private\":false}" \
        "${FORGEJO_API}/orgs/${FORGEJO_ORG}/repos" > /dev/null
else
    echo "    Repository ${FORGEJO_ORG}/${FORGEJO_REPO} already exists"
fi

echo "==> Seeding the repository with the current manifests"
WORK_DIR=$(mktemp -d)
mkdir -p "${WORK_DIR}/k8s/apps" "${WORK_DIR}/k8s/infra"
cp -R "${REPO_ROOT}/k8s/apps/base" "${WORK_DIR}/k8s/apps/base"
cp -R "${REPO_ROOT}/k8s/infra/monitoring" "${WORK_DIR}/k8s/infra/monitoring"
cp -R "${REPO_ROOT}/k8s/infra/monitoring-flux" "${WORK_DIR}/k8s/infra/monitoring-flux"
cp -R "${REPO_ROOT}/k8s/infra/flagsmith" "${WORK_DIR}/k8s/infra/flagsmith"

# The landing page and the UI print browser URLs, which carry the host ingress
# port, Flagsmith builds the links in its own pages from FLAGSMITH_DOMAIN, and
# the Flagsmith dashboard calls FLAGSMITH_ON_FLAGSMITH_API_URL from the
# browser. The manifests hold the default; the seeded copies get whatever
# --ingress-port was given, so those links stay clickable.
if [ "${INGRESS_PORT}" != "8090" ]; then
    echo "    Rewriting landing page, UI, and Flagsmith links for ingress port ${INGRESS_PORT}"
    for f in "${WORK_DIR}/k8s/apps/base/landing.yaml" \
             "${WORK_DIR}/k8s/infra/flagsmith/deployment.yaml" \
             "${WORK_DIR}/k8s/apps/base/ui/index.html"; do
        sed -e "s/localhost:8090/localhost:${INGRESS_PORT}/g" \
            -e "s/host port 8090/host port ${INGRESS_PORT}/g" \
            "${f}" > "${f}.tmp"
        mv "${f}.tmp" "${f}"
    done
fi

(
    cd "${WORK_DIR}"
    git init -q
    git checkout -q -b main
    git -c user.email="${FORGEJO_ADMIN_EMAIL}" -c user.name="${FORGEJO_ADMIN_USER}" add -A
    git -c user.email="${FORGEJO_ADMIN_EMAIL}" -c user.name="${FORGEJO_ADMIN_USER}" commit -q -m "seed: example stack manifests"
    git remote add origin "http://${FORGEJO_ADMIN_USER}:${FORGEJO_TOKEN}@localhost:${FORGEJO_PF_PORT}/${FORGEJO_ORG}/${FORGEJO_REPO}.git"
    git push -f -q origin main
)

echo "    Seed pushed to Forgejo"

# The port-forward stays open: the webhook is created in C6.

# --- C4: Install Flux ---

if kubectl get ns flux-system &>/dev/null; then
    echo "==> Flux already installed"
else
    echo "==> Installing Flux ${FLUX_VERSION}"
    kubectl apply -f "https://github.com/fluxcd/flux2/releases/download/${FLUX_VERSION}/install.yaml"
fi

# The release bundle ships all six controllers. The stack defines no
# image-automation resources, so the two image controllers would idle at real
# CPU cost. Scale them to zero rather than filtering the bundle.
kubectl -n flux-system scale deploy image-reflector-controller image-automation-controller --replicas=0 2>/dev/null || true

mark "Flux install begin"
echo "==> Waiting for Flux controllers"
for deploy in source-controller kustomize-controller helm-controller notification-controller; do
    kubectl -n flux-system wait --for=condition=Available --timeout=180s "deployment/${deploy}"
done

# --- C5: Apply the Flux source and Kustomizations ---

echo "==> Applying Flux sources and Kustomizations"
kubectl apply -k "${REPO_ROOT}/k8s/infra/flux"

# --- C6: Wire the Forgejo webhook to the Flux Receiver ---

echo "==> Waiting for the Flux Receiver to become ready"
RECEIVER_URL=""
for _ in $(seq 1 30); do
    RECEIVER_URL=$(kubectl -n flux-system get receiver forgejo -o jsonpath='{.status.webhookPath}' 2>/dev/null || true)
    if [ -n "${RECEIVER_URL}" ]; then
        break
    fi
    sleep 2
done

if [ -z "${RECEIVER_URL}" ]; then
    echo "WARNING: Flux Receiver not ready after 60s, webhook not configured. Flux still polls."
else
    # The Receiver webhook is cluster-internal; Forgejo calls it at the
    # in-cluster service address.
    WEBHOOK_TARGET="http://notification-controller.flux-system.svc.cluster.local${RECEIVER_URL}"

    EXISTING_HOOKS=$(curl -sf \
        -H "Authorization: token ${FORGEJO_TOKEN}" \
        "${FORGEJO_API}/repos/${FORGEJO_ORG}/${FORGEJO_REPO}/hooks" 2>/dev/null || echo "[]")

    if echo "${EXISTING_HOOKS}" | grep -q "${RECEIVER_URL}"; then
        echo "    Forgejo webhook already configured"
    else
        echo "    Creating the Forgejo webhook for the Flux Receiver"
        curl -sf -X POST \
            -H "Authorization: token ${FORGEJO_TOKEN}" \
            -H "Content-Type: application/json" \
            -d "{
                \"type\": \"forgejo\",
                \"config\": {
                    \"url\": \"${WEBHOOK_TARGET}\",
                    \"content_type\": \"json\",
                    \"secret\": \"example-stack-webhook-secret\"
                },
                \"events\": [\"push\"],
                \"active\": true
            }" \
            "${FORGEJO_API}/repos/${FORGEJO_ORG}/${FORGEJO_REPO}/hooks" > /dev/null
        echo "    Webhook created: push triggers Flux reconciliation"
    fi
fi

kill "${FORGEJO_PF_PID}" 2>/dev/null || true
wait "${FORGEJO_PF_PID}" 2>/dev/null || true
FORGEJO_PF_PID=""

# --- C7: Wait for reconciliation ---

echo "==> Waiting for the Flux GitRepository to fetch from Forgejo"
kubectl -n flux-system wait --for=condition=Ready --timeout=2m gitrepository/example-stack

mark "monitoring reconcile wait begin (the long pull: kube-prometheus-stack)"
echo "==> Waiting for the monitoring Kustomization to reconcile (its HelmRelease installs the custom resource definitions the services depend on; the first install takes several minutes)"
kubectl -n flux-system wait --for=condition=Ready --timeout=20m kustomization/monitoring

echo "==> Waiting for the apps Kustomization to reconcile"
kubectl -n flux-system wait --for=condition=Ready --timeout=5m kustomization/apps

# The namespace exists now, which is why this is not back in C2 where the
# token was minted. The scenario scripts reuse this token instead of minting
# one of their own on every run.
echo "==> Storing the Forgejo access token for the scenario scripts"
write_bootstrap_secret "forgejo-bootstrap" "forgejo" "token=${FORGEJO_TOKEN}"

# --- C8: Roll the services so they pick up freshly built images ---
#
# Builds run before the cluster exists, so the first reconciliation already
# pulls the current images. The restart covers the incremental case, where a
# rebuild under the same tag would not otherwise trigger a redeploy.

echo "==> Rolling restart of the services to pick up rebuilt images"
kubectl -n "${NAMESPACE}" rollout restart deployment/go-api deployment/go-grpc deployment/rust-inventory 2>/dev/null || true
kubectl -n "${NAMESPACE}" rollout status deployment --timeout=120s || true

# --- C9: Seed Flagsmith ---
#
# Flagsmith has no way to create its first user with a known password from the
# environment: the image's bootstrap command creates one with an unusable
# password and prints a reset link. The account is created through the signup
# endpoint instead, which takes a password, answers with the API token the
# rest of the seed uses, and accepts superuser on a self-hosted instance that
# has no users yet. No feature flags are created: no service reads one yet,
# and the dashboard has a built-in default for each of its own.

mark "flagsmith reconcile wait begin (the second long pull: the Flagsmith image)"
echo "==> Waiting for the flagsmith Kustomization to reconcile"
kubectl -n flux-system wait --for=condition=Ready --timeout=10m kustomization/flagsmith

echo "==> Port-forwarding Flagsmith for bootstrap"
kubectl -n "${FLAGSMITH_NS}" port-forward "svc/flagsmith" "${FLAGSMITH_PF_PORT}:8000" &>/dev/null &
FLAGSMITH_PF_PID=$!
FLAGSMITH_LIVENESS="http://localhost:${FLAGSMITH_PF_PORT}/health/liveness/"
for _ in $(seq 1 40); do
    if curl -s -o /dev/null --max-time 1 "${FLAGSMITH_LIVENESS}" 2>/dev/null; then
        break
    fi
    sleep 0.5
done
if ! curl -s -o /dev/null --max-time 1 "${FLAGSMITH_LIVENESS}" 2>/dev/null; then
    echo "ERROR: the Flagsmith port-forward on localhost:${FLAGSMITH_PF_PORT} did not answer within 20s" >&2
    exit 1
fi

FLAGSMITH_API="http://localhost:${FLAGSMITH_PF_PORT}/api/v1"

echo "==> Bootstrapping the Flagsmith admin user"
FLAGSMITH_SIGNUP=$(curl -s -X POST \
    -H "Content-Type: application/json" \
    -d "{\"email\":\"${FLAGSMITH_ADMIN_EMAIL}\",\"password\":\"${FLAGSMITH_PASSWORD}\",\"first_name\":\"Bootstrap\",\"last_name\":\"User\",\"sign_up_type\":\"NO_INVITE\",\"superuser\":true}" \
    "${FLAGSMITH_API}/auth/users/" || echo "")
FLAGSMITH_TOKEN=$(flagsmith_fact "${FLAGSMITH_SIGNUP}" field key || echo "")

if [ -n "${FLAGSMITH_TOKEN}" ]; then
    echo "    Admin user '${FLAGSMITH_ADMIN_EMAIL}' created"
else
    # A re-run against a live cluster finds the account already there, and
    # signup answers 400 rather than a token.
    echo "    Admin user '${FLAGSMITH_ADMIN_EMAIL}' already exists, logging in"
    FLAGSMITH_LOGIN=$(curl -s -X POST \
        -H "Content-Type: application/json" \
        -d "{\"email\":\"${FLAGSMITH_ADMIN_EMAIL}\",\"password\":\"${FLAGSMITH_PASSWORD}\"}" \
        "${FLAGSMITH_API}/auth/login/" || echo "")
    FLAGSMITH_TOKEN=$(flagsmith_fact "${FLAGSMITH_LOGIN}" field key || echo "")
fi

if [ -z "${FLAGSMITH_TOKEN}" ]; then
    echo "ERROR: could not obtain a Flagsmith API token for ${FLAGSMITH_ADMIN_EMAIL}" >&2
    echo "       Signup answered: ${FLAGSMITH_SIGNUP}" >&2
    if [ -n "${FLAGSMITH_LOGIN:-}" ]; then
        echo "       Login answered: ${FLAGSMITH_LOGIN}" >&2
    fi
    exit 1
fi

echo "==> Ensuring the Flagsmith organization and project exist"
FLAGSMITH_ORG_ID=$(flagsmith_fact "$(flagsmith_api GET /organisations/)" find "${FLAGSMITH_ORG}" id || echo "")
if [ -n "${FLAGSMITH_ORG_ID}" ]; then
    echo "    Organization '${FLAGSMITH_ORG}' already exists"
else
    # The JSON bodies are built into a variable first. bash 3.2 loses the
    # quoting of an escaped-quote body nested inside "$(...)", and brace-
    # expands the {"a":1,"b":2} into two words, so every body with a comma
    # was sent as two broken requests.
    body='{"name":"'"${FLAGSMITH_ORG}"'"}'
    response=$(flagsmith_api POST /organisations/ "${body}")
    FLAGSMITH_ORG_ID=$(flagsmith_fact "${response}" field id || echo "")
    if [ -z "${FLAGSMITH_ORG_ID}" ]; then
        echo "ERROR: could not create the Flagsmith organization '${FLAGSMITH_ORG}'" >&2
        echo "       Flagsmith answered: ${response}" >&2
        exit 1
    fi
    echo "    Organization '${FLAGSMITH_ORG}' created"
fi

FLAGSMITH_PROJECT_ID=$(flagsmith_fact "$(flagsmith_api GET /projects/)" find "${FLAGSMITH_PROJECT}" id || echo "")
if [ -n "${FLAGSMITH_PROJECT_ID}" ]; then
    echo "    Project '${FLAGSMITH_PROJECT}' already exists"
else
    body='{"name":"'"${FLAGSMITH_PROJECT}"'","organisation":'"${FLAGSMITH_ORG_ID}"'}'
    response=$(flagsmith_api POST /projects/ "${body}")
    FLAGSMITH_PROJECT_ID=$(flagsmith_fact "${response}" field id || echo "")
    if [ -z "${FLAGSMITH_PROJECT_ID}" ]; then
        echo "ERROR: could not create the Flagsmith project '${FLAGSMITH_PROJECT}'" >&2
        echo "       Flagsmith answered: ${response}" >&2
        exit 1
    fi
    echo "    Project '${FLAGSMITH_PROJECT}' created"
fi

# The two environment names the services will read later. Anything else the
# project carries is removed, so a Flagsmith release that starts creating a
# default environment on project create does not leave one behind.
echo "==> Ensuring the Flagsmith environments exist"
FLAGSMITH_ENVS=$(flagsmith_api GET "/environments/?project=${FLAGSMITH_PROJECT_ID}")

while IFS= read -r env_name; do
    [ -n "${env_name}" ] || continue
    case "${env_name}" in
        staging|production) continue ;;
    esac
    env_key=$(flagsmith_fact "${FLAGSMITH_ENVS}" find "${env_name}" api_key || echo "")
    if [ -n "${env_key}" ]; then
        echo "    Removing the default environment '${env_name}'"
        flagsmith_api DELETE "/environments/${env_key}/" > /dev/null
    fi
done <<EOF
$(flagsmith_fact "${FLAGSMITH_ENVS}" names || true)
EOF

FLAGSMITH_STAGING_KEY=""
FLAGSMITH_PRODUCTION_KEY=""
for env_name in staging production; do
    env_key=$(flagsmith_fact "${FLAGSMITH_ENVS}" find "${env_name}" api_key || echo "")
    if [ -n "${env_key}" ]; then
        echo "    Environment '${env_name}' already exists"
    else
        body='{"name":"'"${env_name}"'","project":'"${FLAGSMITH_PROJECT_ID}"'}'
        response=$(flagsmith_api POST /environments/ "${body}")
        env_key=$(flagsmith_fact "${response}" field api_key || echo "")
        if [ -z "${env_key}" ]; then
            echo "ERROR: could not create the Flagsmith environment '${env_name}'" >&2
            echo "       Flagsmith answered: ${response}" >&2
            exit 1
        fi
        echo "    Environment '${env_name}' created"
    fi
    case "${env_name}" in
        staging)    FLAGSMITH_STAGING_KEY="${env_key}" ;;
        production) FLAGSMITH_PRODUCTION_KEY="${env_key}" ;;
    esac
done

# The admin token joins the two environment keys so a later run, a scenario,
# or a person has an authenticated way into Flagsmith without signing in
# again. validate-stack.sh reads the two environment keys back out to check
# the seeded project; nothing else reads any of it yet, and the SDKs will
# read the environment keys.
echo "==> Writing the Flagsmith bootstrap Secret into the ${NAMESPACE} namespace"
write_bootstrap_secret "flagsmith-bootstrap" "flagsmith" \
    "admin-token=${FLAGSMITH_TOKEN}" \
    "production=${FLAGSMITH_PRODUCTION_KEY}" \
    "staging=${FLAGSMITH_STAGING_KEY}"

# The dashboard reads its own feature flags from a Flagsmith, the vendor's
# hosted one unless the Deployment names another. This project is what it is
# pointed at instead, per Flagsmith's "Running Flagsmith on Flagsmith" docs.
# It lives in its own organization because Flagsmith's free plan, the default
# on a self-hosted instance too, allows one project per organization.
# The API creates no environment with a project (the dashboard's own
# create-project form adds them), so the one environment is found or created
# by name like the others.
echo "==> Ensuring the Flagsmith organization and project for the dashboard's own flags exist"
FLAGSMITH_DASHBOARD_ORG_ID=$(flagsmith_fact "$(flagsmith_api GET /organisations/)" find "${FLAGSMITH_DASHBOARD_PROJECT}" id || echo "")
if [ -n "${FLAGSMITH_DASHBOARD_ORG_ID}" ]; then
    echo "    Organization '${FLAGSMITH_DASHBOARD_PROJECT}' already exists"
else
    body='{"name":"'"${FLAGSMITH_DASHBOARD_PROJECT}"'"}'
    response=$(flagsmith_api POST /organisations/ "${body}")
    FLAGSMITH_DASHBOARD_ORG_ID=$(flagsmith_fact "${response}" field id || echo "")
    if [ -z "${FLAGSMITH_DASHBOARD_ORG_ID}" ]; then
        echo "ERROR: could not create the Flagsmith organization '${FLAGSMITH_DASHBOARD_PROJECT}'" >&2
        echo "       Flagsmith answered: ${response}" >&2
        exit 1
    fi
    echo "    Organization '${FLAGSMITH_DASHBOARD_PROJECT}' created"
fi
FLAGSMITH_DASHBOARD_PROJECT_ID=$(flagsmith_fact "$(flagsmith_api GET /projects/)" find "${FLAGSMITH_DASHBOARD_PROJECT}" id || echo "")
if [ -n "${FLAGSMITH_DASHBOARD_PROJECT_ID}" ]; then
    echo "    Project '${FLAGSMITH_DASHBOARD_PROJECT}' already exists"
else
    body='{"name":"'"${FLAGSMITH_DASHBOARD_PROJECT}"'","organisation":'"${FLAGSMITH_DASHBOARD_ORG_ID}"'}'
    response=$(flagsmith_api POST /projects/ "${body}")
    FLAGSMITH_DASHBOARD_PROJECT_ID=$(flagsmith_fact "${response}" field id || echo "")
    if [ -z "${FLAGSMITH_DASHBOARD_PROJECT_ID}" ]; then
        echo "ERROR: could not create the Flagsmith project '${FLAGSMITH_DASHBOARD_PROJECT}'" >&2
        echo "       Flagsmith answered: ${response}" >&2
        exit 1
    fi
    echo "    Project '${FLAGSMITH_DASHBOARD_PROJECT}' created"
fi

FLAGSMITH_DASHBOARD_ENVS=$(flagsmith_api GET "/environments/?project=${FLAGSMITH_DASHBOARD_PROJECT_ID}")
FLAGSMITH_DASHBOARD_KEY=$(flagsmith_fact "${FLAGSMITH_DASHBOARD_ENVS}" find "${FLAGSMITH_DASHBOARD_ENV}" api_key || echo "")
if [ -n "${FLAGSMITH_DASHBOARD_KEY}" ]; then
    echo "    Environment '${FLAGSMITH_DASHBOARD_ENV}' already exists"
else
    body='{"name":"'"${FLAGSMITH_DASHBOARD_ENV}"'","project":'"${FLAGSMITH_DASHBOARD_PROJECT_ID}"'}'
    response=$(flagsmith_api POST /environments/ "${body}")
    FLAGSMITH_DASHBOARD_KEY=$(flagsmith_fact "${response}" field api_key || echo "")
    if [ -z "${FLAGSMITH_DASHBOARD_KEY}" ]; then
        echo "ERROR: could not create the Flagsmith environment '${FLAGSMITH_DASHBOARD_ENV}'" >&2
        echo "       Flagsmith answered: ${response}" >&2
        exit 1
    fi
    echo "    Environment '${FLAGSMITH_DASHBOARD_ENV}' created"
fi

# What the running server hands the dashboard, read before the port-forward
# closes. Comparing against this rather than the Secret's old value means a
# run interrupted between the Secret write and the restart, or a Secret
# edited by hand, still ends with a restart.
FLAGSMITH_DASHBOARD_SERVED=$(curl -s --max-time 5 \
    "http://localhost:${FLAGSMITH_PF_PORT}/config/project-overrides" 2>/dev/null || true)

kill "${FLAGSMITH_PF_PID}" 2>/dev/null || true
wait "${FLAGSMITH_PF_PID}" 2>/dev/null || true
FLAGSMITH_PF_PID=""

# The Deployment reads the key from this Secret, optionally, so Flagsmith
# starts before the seed has run. Django reads its settings once, at process
# start, so a key it is not already serving reaches the dashboard only
# through a restart.
echo "==> Writing the dashboard's client-side key into the ${FLAGSMITH_NS} namespace"
write_bootstrap_secret -n "${FLAGSMITH_NS}" "flagsmith-dashboard" "flagsmith" \
    "client-key=${FLAGSMITH_DASHBOARD_KEY}"
case "${FLAGSMITH_DASHBOARD_SERVED}" in
    *"\"flagsmith\": \"${FLAGSMITH_DASHBOARD_KEY}\""*)
        echo "    Flagsmith already serves this key to the dashboard, not restarting"
        ;;
    *)
        mark "flagsmith restart begin"
        echo "==> Restarting Flagsmith so the dashboard reads its own flags from this instance"
        kubectl -n "${FLAGSMITH_NS}" rollout restart deployment/flagsmith
        kubectl -n "${FLAGSMITH_NS}" rollout status deployment/flagsmith --timeout=5m
        ;;
esac

# =============================================================================
# Phase D: Smoke
# =============================================================================

echo ""
echo "=== Phase D: Smoke ==="
mark "Phase D begin"

echo ""
echo "==> Namespaces:"
kubectl get ns | grep -E "${NAMESPACE}|${FORGEJO_NS}|flux-system|${MONITORING_NS}|${FLAGSMITH_NS}" || true

echo ""
echo "==> Pods in ${NAMESPACE}:"
kubectl -n "${NAMESPACE}" get pods

echo ""
echo "==> Pods in ${MONITORING_NS}:"
kubectl -n "${MONITORING_NS}" get pods 2>/dev/null || echo "    monitoring namespace not ready yet"

echo ""
echo "==> Services in ${NAMESPACE}:"
kubectl -n "${NAMESPACE}" get svc

echo ""
echo "==> Running the smoke test"
SMOKE_OK=1
bash "${SCRIPT_DIR}/smoke-test.sh" --kubeconfig-path="${KUBECONFIG_PATH}" || SMOKE_OK=0

# =============================================================================
# Summary
# =============================================================================

echo ""
if [ "${SMOKE_OK}" -eq 1 ]; then
    echo "==> Done."
else
    echo "==> Smoke test failed. The cluster is up; the services are not behaving."
fi
mark "finished (total elapsed)"
echo ""
echo "    Access points (through the k3d Traefik ingress on host port ${INGRESS_PORT}):"
echo "    - Landing page:   http://example-stack.localhost:${INGRESS_PORT}/"
echo "    - Order UI:       http://ui.localhost:${INGRESS_PORT}/"
echo "    - go-api:         http://goapi.localhost:${INGRESS_PORT}/"
echo "    - rust-inventory: http://rust.localhost:${INGRESS_PORT}/"
echo "    - Forgejo:        http://forgejo.localhost:${INGRESS_PORT}/ (${FORGEJO_ADMIN_USER} / ${FORGEJO_PASSWORD}, demo-only)"
echo "    - Grafana:        http://grafana.localhost:${INGRESS_PORT}/ (admin / admin, demo-only)"
echo "    - Flagsmith:      http://flagsmith.localhost:${INGRESS_PORT}/ (${FLAGSMITH_ADMIN_EMAIL} / ${FLAGSMITH_PASSWORD}, demo-only)"
echo "    - Prometheus:     http://prometheus.localhost:${INGRESS_PORT}/"
echo ""
echo "    kubectl reaches this cluster with KUBECONFIG=${KUBECONFIG_PATH}."
echo ""
echo "    go-grpc speaks HTTP/2 only and is not exposed through the ingress:"
echo "    - go-grpc:        kubectl -n ${NAMESPACE} port-forward svc/go-grpc 19090:9090"

# The access points print either way: a failed smoke test is exactly when they
# are wanted.
if [ "${SMOKE_OK}" -ne 1 ]; then
    exit 1
fi
