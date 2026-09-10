#!/usr/bin/env bash
set -euo pipefail

# Brings up the example stack: local registry, k3d cluster, images, an
# in-cluster Forgejo holding the manifests, Flux reconciling from it, the
# monitoring stack, the services, and a smoke test.
#
# Phases are ordered so a failure costs as little as possible. The registry and
# the image builds run before any cluster exists, so a broken build never
# leaves a cluster behind. Every phase checks for the state it would create, so
# re-running the script against a live cluster reconciles instead of starting
# over.
#
#   A. Builds       local registry up, service images built and pushed
#   B. Cluster      k3d cluster created and wired to the registry
#   C. Deploy       Forgejo, Flux, monitoring, services
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
  --help                    Show this message
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --cluster-name=*)     CLUSTER_NAME="${1#*=}" ;;
        --registry-name=*)    REGISTRY_NAME="${1#*=}" ;;
        --registry-port=*)    REGISTRY_PORT="${1#*=}" ;;
        --ingress-port=*)     INGRESS_PORT="${1#*=}" ;;
        --k8s-api-port=*)     K8S_API_PORT="${1#*=}" ;;
        --kubeconfig-path=*)  KUBECONFIG_PATH="${1#*=}" ;;
        --forgejo-password=*) FORGEJO_PASSWORD="${1#*=}" ;;
        --help|-h)            usage; exit 0 ;;
        *)                    echo "ERROR: unknown flag '$1'" >&2; echo "" >&2; usage >&2; exit 1 ;;
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
WORK_DIR=""

cleanup() {
    if [ -n "${FORGEJO_PF_PID}" ]; then
        kill "${FORGEJO_PF_PID}" 2>/dev/null || true
        wait "${FORGEJO_PF_PID}" 2>/dev/null || true
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
        return 0
    fi
    if [ "${state}" != "running" ]; then
        echo "ERROR: the podman machine is ${state}; start it with 'podman machine start'" >&2
        exit 1
    fi

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
    k3d cluster create "${CLUSTER_NAME}" \
        --image "${K3S_IMAGE}" \
        --agents 1 \
        --api-port "${K8S_API_PORT}" \
        --port "${INGRESS_PORT}:80@loadbalancer" \
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
sleep 2

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

# The landing page and the UI print browser URLs, which carry the host ingress
# port. The manifests hold the default; the seeded copies get whatever
# --ingress-port was given, so those links stay clickable.
if [ "${INGRESS_PORT}" != "8090" ]; then
    echo "    Rewriting landing page and UI links for ingress port ${INGRESS_PORT}"
    for f in "${WORK_DIR}/k8s/apps/base/landing.yaml" \
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

# --- C8: Roll the services so they pick up freshly built images ---
#
# Builds run before the cluster exists, so the first reconciliation already
# pulls the current images. The restart covers the incremental case, where a
# rebuild under the same tag would not otherwise trigger a redeploy.

echo "==> Rolling restart of the services to pick up rebuilt images"
kubectl -n "${NAMESPACE}" rollout restart deployment/go-api deployment/go-grpc deployment/rust-inventory 2>/dev/null || true
kubectl -n "${NAMESPACE}" rollout status deployment --timeout=120s || true

# =============================================================================
# Phase D: Smoke
# =============================================================================

echo ""
echo "=== Phase D: Smoke ==="
mark "Phase D begin"

echo ""
echo "==> Namespaces:"
kubectl get ns | grep -E "${NAMESPACE}|${FORGEJO_NS}|flux-system|${MONITORING_NS}" || true

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
