#!/usr/bin/env bash
set -euo pipefail

# Checks that the stack's infrastructure is wired correctly: pods running,
# ingress resolving, metrics endpoints responding, Prometheus scraping every
# expected target, Flux reconciling. Complements smoke-test.sh, which checks
# service behavior.
#
# Invoke with: bash scripts/validate-stack.sh

KUBECONFIG_PATH="${HOME}/.kube/example-stack.yaml"
INGRESS_PORT="8090"

usage() {
    cat <<EOF
Usage: $(basename "$0") [config-flags...]

Config flags (all optional, defaults shown):
  --ingress-port=PORT       8090
  --kubeconfig-path=PATH    \$HOME/.kube/example-stack.yaml
  --help                    Show this message
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --ingress-port=*)    INGRESS_PORT="${1#*=}" ;;
        --kubeconfig-path=*) KUBECONFIG_PATH="${1#*=}" ;;
        --help|-h)           usage; exit 0 ;;
        *)                   echo "ERROR: unknown flag '$1'" >&2; echo "" >&2; usage >&2; exit 1 ;;
    esac
    shift
done

export KUBECONFIG="${KUBECONFIG_PATH}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Fixed, not a flag: every manifest in k8s/apps/base names this namespace.
NAMESPACE="example-stack"
MONITORING_NS="monitoring"
FLUX_NS="flux-system"
FORGEJO_NS="forgejo"
FAILED=0

pass() { echo "  PASS  $1"; }
fail() { echo "  FAIL  $1"; FAILED=1; }

# One Python program answers every question this script asks of a Prometheus
# API response. The response arrives as a string, so it is piped back in.
prom_fact() {
    local response="$1"
    shift
    printf '%s' "${response}" | python3 "${SCRIPT_DIR}/promjson.py" "$@" 2>/dev/null || echo "error"
}

check_pods() {
    local ns="$1"
    local label="$2"
    local description="$3"
    local count
    # grep -c prints 0 and exits 1 when it matches nothing, so a || fallback
    # here would print a second 0 and the comparison below would fail to parse.
    count=$(kubectl -n "${ns}" get pods -l "${label}" --no-headers 2>/dev/null | grep -c Running) || count=0
    if [ "${count}" -gt 0 ]; then
        pass "${description} (${count} running)"
    else
        fail "${description} (0 running)"
    fi
}

check_url() {
    local description="$1"
    local url="$2"
    local expect="${3:-200}"
    local status
    status=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "${url}" 2>/dev/null || echo "000")
    if [ "${status}" = "${expect}" ]; then
        pass "${description} (${status})"
    else
        fail "${description} (got ${status}, expected ${expect})"
    fi
}

# --- Pods ---

echo "==> Pod health"
check_pods "${NAMESPACE}" "app=go-api" "go-api"
check_pods "${NAMESPACE}" "app=go-grpc" "go-grpc"
check_pods "${NAMESPACE}" "app=rust-inventory" "rust-inventory"
check_pods "${NAMESPACE}" "app=landing" "landing"
check_pods "${NAMESPACE}" "app=ui" "ui"
check_pods "${NAMESPACE}" "app=postgres" "postgres"

# --- Migration jobs ---

echo ""
echo "==> Migration jobs"

# Finished Jobs are garbage-collected ten minutes after completion; a missing
# Job is not a failure, and the seed data the smoke test checks is the proof
# the migration ran.
check_job() {
    local ns="$1"
    local name="$2"
    local succeeded
    if ! kubectl -n "${ns}" get job "${name}" >/dev/null 2>&1; then
        pass "${name} already garbage-collected"
        return 0
    fi
    succeeded=$(kubectl -n "${ns}" get job "${name}" -o jsonpath='{.status.succeeded}' 2>/dev/null || echo "0")
    if [ "${succeeded}" = "1" ]; then
        pass "${name} succeeded"
    else
        fail "${name} (succeeded=${succeeded})"
    fi
}

check_job "${NAMESPACE}" "migrate-inventory-v1"
check_job "${NAMESPACE}" "migrate-orders-v1"

echo ""
echo "==> Pod health (continued)"
check_pods "${FORGEJO_NS}" "app=forgejo" "forgejo"
check_pods "${MONITORING_NS}" "app.kubernetes.io/name=grafana" "grafana"
check_pods "${MONITORING_NS}" "app.kubernetes.io/name=prometheus" "prometheus"
check_pods "${FLUX_NS}" "app=source-controller" "flux source-controller"
check_pods "${FLUX_NS}" "app=kustomize-controller" "flux kustomize-controller"
check_pods "${FLUX_NS}" "app=helm-controller" "flux helm-controller"

# --- Ingress ---

echo ""
echo "==> Ingress (through Traefik on host port ${INGRESS_PORT})"
check_url "landing page" "http://example-stack.localhost:${INGRESS_PORT}/"
check_url "ui /" "http://ui.localhost:${INGRESS_PORT}/"
check_url "go-api /healthz" "http://goapi.localhost:${INGRESS_PORT}/healthz"
check_url "rust-inventory /healthz" "http://rust.localhost:${INGRESS_PORT}/healthz"
check_url "forgejo" "http://forgejo.localhost:${INGRESS_PORT}/"
check_url "grafana" "http://grafana.localhost:${INGRESS_PORT}/" "302"
check_url "prometheus" "http://prometheus.localhost:${INGRESS_PORT}/" "302"

# --- Metrics endpoints (via port-forward) ---

echo ""
echo "==> Metrics endpoints"

cleanup_pf() {
    kill %1 %2 %3 2>/dev/null || true
    wait 2>/dev/null || true
}
trap cleanup_pf EXIT

# A port-forward answers a few hundred milliseconds after it starts on an
# idle machine and several seconds on one still loading images, so each
# forwarded port is polled until it accepts a request.
wait_for_port() {
    local port="$1"
    for _ in $(seq 1 40); do
        if curl -s -o /dev/null --max-time 1 "http://localhost:${port}/" 2>/dev/null; then
            return 0
        fi
        sleep 0.5
    done
    echo "  WARN  port-forward on ${port} not answering after 20s" >&2
    return 1
}

kubectl -n "${NAMESPACE}" port-forward svc/go-api 18080:8080 &>/dev/null &
kubectl -n "${NAMESPACE}" port-forward svc/go-grpc 19091:9091 &>/dev/null &
kubectl -n "${NAMESPACE}" port-forward svc/rust-inventory 18081:8081 &>/dev/null &
wait_for_port 18080; wait_for_port 19091; wait_for_port 18081

check_url "go-api /metrics" "http://localhost:18080/metrics"
check_url "go-grpc /metrics" "http://localhost:19091/metrics"
check_url "rust-inventory /metrics" "http://localhost:18081/metrics"

kill %1 %2 %3 2>/dev/null || true
wait 2>/dev/null || true
trap - EXIT

# --- Prometheus targets ---

echo ""
echo "==> Prometheus targets"

# Prometheus picks up a new ServiceMonitor on its next configuration reload,
# which lands a minute or two after the apps Kustomization reconciles, and a
# target it has just discovered reports "unknown" health until its first
# scrape. Run straight after a bring-up the service targets are not there or
# not yet scraped, so the list is polled until all three are up.
PROM_TARGETS='{"data":{"activeTargets":[]}}'
for _ in $(seq 1 30); do
    PROM_TARGETS=$(curl -s --max-time 5 "http://prometheus.localhost:${INGRESS_PORT}/api/v1/targets?state=active" || echo '{"data":{"activeTargets":[]}}')
    NOT_UP=0
    for job in go-api go-grpc rust-inventory; do
        [ "$(prom_fact "${PROM_TARGETS}" target-health "${job}")" = "up" ] || NOT_UP=1
    done
    if [ "${NOT_UP}" -eq 0 ]; then
        break
    fi
    sleep 10
done

check_prom_target() {
    local description="$1"
    local job_pattern="$2"
    local health
    health=$(prom_fact "${PROM_TARGETS}" target-health "${job_pattern}")
    if [ "${health}" = "up" ]; then
        pass "${description} (${health})"
    elif [ "${health}" = "missing" ]; then
        fail "${description} (not found in active targets)"
    else
        fail "${description} (${health})"
    fi
}

check_prom_target "go-api scrape" "go-api"
check_prom_target "go-grpc scrape" "go-grpc"
check_prom_target "rust-inventory scrape" "rust-inventory"
check_prom_target "kps-prometheus self-scrape" "kps-prometheus"
check_prom_target "kps-alertmanager" "kps-alertmanager"
check_prom_target "grafana" "kube-prometheus-stack-grafana"
check_prom_target "kube-state-metrics" "kube-state-metrics"
check_prom_target "node-exporter" "node-exporter"

# Check Flux PodMonitor targets (gotk_* metrics)
check_prom_target "flux controllers" "flux-system/flux-controllers"

FLUX_METRICS=$(prom_fact "${PROM_TARGETS}" target-count "flux-system/flux-controllers")
case "${FLUX_METRICS}" in
    ''|*[!0-9]*) FLUX_METRICS=0 ;;
esac

if [ "${FLUX_METRICS}" -gt 0 ]; then
    pass "flux controller endpoints (${FLUX_METRICS} scraped)"
else
    fail "flux controller endpoints (0 scraped, the PodMonitor may not be applied yet)"
fi

# --- Recording rules produce samples ---

echo ""
echo "==> Latency recording rules"

# A wrong metric name leaves a recording rule healthy and empty, so the rules
# are checked for samples and not only for health. Creating an order drives all
# three services: go-api over HTTP, the rust-inventory stock call, and the
# go-grpc price RPC.
create_order() {
    curl -s -o /dev/null --max-time 5 -X POST \
        -H "Authorization: Bearer dev-token" \
        -H "Content-Type: application/json" \
        -d '{"item_id":"a0000000-0000-0000-0000-000000000001","quantity":1}' \
        "http://goapi.localhost:${INGRESS_PORT}/api/v1/orders" || true
}

for _ in 1 2 3 4 5; do
    create_order
done

# The recording rule group evaluates every 15s.
sleep 20

check_recording_rule() {
    local description="$1"
    local rule="$2"
    local value=""
    # A quantile over a rate needs two scrapes that differ, so traffic keeps
    # flowing while this polls: a burst that all landed before the first
    # scrape of a fresh target leaves the rate at zero and the quantile NaN.
    local response
    for _ in $(seq 1 12); do
        create_order
        response=$(curl -s --max-time 5 --get \
            --data-urlencode "query=${rule}" \
            "http://prometheus.localhost:${INGRESS_PORT}/api/v1/query" || echo "")
        value=$(prom_fact "${response}" query-value)
        case "${value}" in
            none|error|NaN) sleep 10 ;;
            *)              break ;;
        esac
    done
    case "${value}" in
        none|error|NaN) fail "${description} (no samples: ${value})" ;;
        *)              pass "${description} (${value}s)" ;;
    esac
}

check_recording_rule "go-api p99 latency" "goapi:http_latency_p99:5m"
check_recording_rule "go-grpc p99 latency" "gogrpc:grpc_latency_p99:5m"
check_recording_rule "rust-inventory p99 latency" "rustinventory:http_latency_p99:5m"

# --- Prometheus alert rules loaded ---

echo ""
echo "==> Prometheus alert rules"

PROM_RULES=$(curl -s --max-time 5 "http://prometheus.localhost:${INGRESS_PORT}/api/v1/rules?type=alert" || echo '{"data":{"groups":[]}}')

EXPECTED_ALERTS=(
    GoApiHighErrorRate
    GoApiHighLatency
    GoGrpcHighErrorRate
    GoGrpcHighLatency
    RustInventoryHighErrorRate
    RustInventoryHighLatency
    ExampleAppCrashLooping
    ExampleAppNotReady
    ExampleAppReplicasMismatch
)

for alert in "${EXPECTED_ALERTS[@]}"; do
    HEALTH=$(prom_fact "${PROM_RULES}" rule-health "${alert}")
    if [ "${HEALTH}" = "ok" ]; then
        pass "alert rule ${alert} (${HEALTH})"
    else
        fail "alert rule ${alert} (${HEALTH})"
    fi
done

# --- Prometheus alert state ---

echo ""
echo "==> Prometheus alert state"

# Alerts in this list are allowed to be firing. Curate based on observed
# steady state on this stack. Add entries with a comment explaining why the
# alert is expected to fire at baseline.
EXPECTED_FIRING=(
    # kube-prometheus-stack ships Watchdog as a deadman's switch: it fires
    # always, so a receiver can tell "nothing is wrong" from "nothing is
    # reaching me". Its absence is the problem, not its presence.
    Watchdog
)

PROM_ALERTS=$(curl -s --max-time 5 "http://prometheus.localhost:${INGRESS_PORT}/api/v1/alerts" || echo '{"data":{"alerts":[]}}')

FIRING_ALERTS=$(prom_fact "${PROM_ALERTS}" firing-alerts)
if [ "${FIRING_ALERTS}" = "error" ]; then
    fail "could not read the Prometheus alert list"
    FIRING_ALERTS=""
fi

if [ -z "${FIRING_ALERTS}" ]; then
    pass "no alerts firing"
else
    UNEXPECTED=""
    for alert in ${FIRING_ALERTS}; do
        is_expected=0
        if [ "${#EXPECTED_FIRING[@]}" -gt 0 ]; then
            for e in "${EXPECTED_FIRING[@]}"; do
                if [ "${alert}" = "${e}" ]; then
                    is_expected=1
                    break
                fi
            done
        fi
        if [ "${is_expected}" = "0" ]; then
            UNEXPECTED="${UNEXPECTED} ${alert}"
        fi
    done
    if [ -z "${UNEXPECTED}" ]; then
        pass "only expected alerts firing (${FIRING_ALERTS})"
    else
        fail "unexpected alerts firing:${UNEXPECTED}"
        echo "        If this firing state is expected (for example after a"
        echo "        scenario demo), add the alert name to EXPECTED_FIRING in"
        echo "        this script with a comment explaining why. Firing alerts"
        echo "        can take 5 to 7 minutes to clear after a scenario reset,"
        echo "        given the rate([5m]) window and the for:2m clause."
    fi
fi

# --- Flux reconciliation ---

echo ""
echo "==> Flux reconciliation"

for ks in apps monitoring; do
    READY=$(kubectl -n "${FLUX_NS}" get kustomization "${ks}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")
    if [ "${READY}" = "True" ]; then
        pass "kustomization/${ks} ready"
    else
        fail "kustomization/${ks} (ready=${READY})"
    fi
done

HR_READY=$(kubectl -n "${MONITORING_NS}" get helmrelease kube-prometheus-stack -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")
if [ "${HR_READY}" = "True" ]; then
    pass "helmrelease/kube-prometheus-stack ready"
else
    fail "helmrelease/kube-prometheus-stack (ready=${HR_READY})"
fi

GR_READY=$(kubectl -n "${FLUX_NS}" get gitrepository example-stack -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")
if [ "${GR_READY}" = "True" ]; then
    pass "gitrepository/example-stack ready"
else
    fail "gitrepository/example-stack (ready=${GR_READY})"
fi

RECV_READY=$(kubectl -n "${FLUX_NS}" get receiver forgejo -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")
if [ "${RECV_READY}" = "True" ]; then
    pass "receiver/forgejo ready"
else
    fail "receiver/forgejo (ready=${RECV_READY})"
fi

# --- Summary ---

echo ""
if [ "${FAILED}" -eq 0 ]; then
    echo "==> All checks passed"
else
    echo "==> Some checks failed"
    exit 1
fi
