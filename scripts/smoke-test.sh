#!/usr/bin/env bash
set -euo pipefail

# Smoke test for the services (go-api, rust-inventory, go-grpc, ui) in the
# example-stack namespace, reached by port-forward through the cluster's own
# kubeconfig.
#
# The local port-forward ports sit in the 18000 range, where they are unlikely
# to collide with anything already running on the host.
#
# Invoke with: bash scripts/smoke-test.sh

KUBECONFIG_PATH="${HOME}/.kube/example-stack.yaml"

usage() {
    cat <<EOF
Usage: $(basename "$0") [config-flags...]

Config flags (all optional, defaults shown):
  --kubeconfig-path=PATH    \$HOME/.kube/example-stack.yaml
  --help                    Show this message
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --kubeconfig-path=*) KUBECONFIG_PATH="${1#*=}" ;;
        --help|-h)           usage; exit 0 ;;
        *)                   echo "ERROR: unknown flag '$1'" >&2; echo "" >&2; usage >&2; exit 1 ;;
    esac
    shift
done

export KUBECONFIG="${KUBECONFIG_PATH}"

# Fixed, not a flag: every manifest in k8s/apps/base names this namespace.
NAMESPACE="example-stack"
FAILED=0

BODY_FILE="$(mktemp)"

cleanup() {
    kill %1 %2 %3 %4 2>/dev/null || true
    wait 2>/dev/null || true
    rm -f "${BODY_FILE}"
}
trap cleanup EXIT

# --- Port forwards ---

kubectl -n "${NAMESPACE}" port-forward svc/go-api 18080:8080 &>/dev/null &
kubectl -n "${NAMESPACE}" port-forward svc/rust-inventory 18081:8081 &>/dev/null &
kubectl -n "${NAMESPACE}" port-forward svc/go-grpc 19090:9090 &>/dev/null &
kubectl -n "${NAMESPACE}" port-forward svc/ui 18082:80 &>/dev/null &
sleep 2

# --- Helper ---

check() {
    local label="$1"
    local cmd="$2"
    local expect_status="${3:-200}"

    local status
    local body
    local response
    response=$(eval "${cmd}" -o "${BODY_FILE}" -w "%{http_code}" -s 2>&1)
    status="${response}"
    body=$(cat "${BODY_FILE}" 2>/dev/null || echo "")

    if [ "$status" = "$expect_status" ]; then
        echo "  PASS  ${label} (${status})"
        echo "        ${body}"
    else
        echo "  FAIL  ${label} (got ${status}, expected ${expect_status})"
        echo "        ${body}"
        FAILED=1
    fi
}

# grpcurl takes none of curl's flags, so it needs its own check: run the
# command as given, then judge it by its exit status and by what it printed.
check_grpc() {
    local label="$1"
    local expect="$2"
    shift 2

    local output status
    output=$("$@" 2>&1) && status=0 || status=$?

    if [ "${status}" -ne 0 ]; then
        echo "  FAIL  ${label} (grpcurl exited ${status})"
        echo "        ${output}"
        FAILED=1
    elif ! printf '%s' "${output}" | grep -q "${expect}"; then
        echo "  FAIL  ${label} (response did not contain ${expect})"
        echo "        ${output}"
        FAILED=1
    else
        echo "  PASS  ${label}"
        echo "        $(printf '%s' "${output}" | tr '\n' ' ')"
    fi
}

# --- Migration jobs ---

echo "==> Migration jobs"
# Finished Jobs are garbage-collected ten minutes after completion, so on a
# stack that has been up a while the Job is gone. Its absence is not a failure:
# the seed-data checks below prove the migration ran.
for job in migrate-inventory-v1 migrate-orders-v1; do
    if ! kubectl -n "${NAMESPACE}" get job "${job}" >/dev/null 2>&1; then
        echo "  PASS  ${job} already garbage-collected"
        continue
    fi
    STATUS=$(kubectl -n "${NAMESPACE}" get job "${job}" -o jsonpath='{.status.succeeded}' 2>/dev/null || echo "0")
    if [ "${STATUS}" = "1" ]; then
        echo "  PASS  ${job} succeeded"
    else
        echo "  FAIL  ${job} not succeeded (status: ${STATUS})"
        FAILED=1
    fi
done

# --- rust-inventory (backend) ---

echo ""
echo "==> rust-inventory"
check "GET /healthz" \
    "curl http://localhost:18081/healthz"

check "GET /readyz" \
    "curl http://localhost:18081/readyz"

check "POST /api/v1/inventory (no auth)" \
    "curl -X POST http://localhost:18081/api/v1/inventory -H 'Content-Type: application/json' -d '{\"name\":\"test\",\"quantity\":1,\"warehouse\":\"x\"}'" \
    "401"

check "GET /api/v1/inventory (seeded data)" \
    "curl http://localhost:18081/api/v1/inventory -H 'Authorization: Bearer dev-token'"

# Verify seed data exists
SEED_COUNT=$(curl -s http://localhost:18081/api/v1/inventory -H 'Authorization: Bearer dev-token' | python3 -c "import json,sys; print(json.load(sys.stdin).get('count',0))" 2>/dev/null || echo "0")
if [ "${SEED_COUNT}" -ge 3 ]; then
    echo "  PASS  seed data present (${SEED_COUNT} items)"
else
    echo "  FAIL  seed data missing (${SEED_COUNT} items, expected >= 3)"
    FAILED=1
fi

# --- go-grpc (backend) ---

echo ""
echo "==> go-grpc"
if command -v grpcurl &>/dev/null; then
    echo "  (grpcurl available, testing gRPC)"
    check_grpc "EchoService/Health" "SERVING" \
        grpcurl -plaintext localhost:19090 echo.v1.EchoService/Health

    check_grpc "PricingService/GetPrice" "total" \
        grpcurl -plaintext \
        -H "authorization: Bearer dev-token" \
        -d '{"item_id":"a0000000-0000-0000-0000-000000000001","quantity":5}' \
        localhost:19090 pricing.v1.PricingService/GetPrice
else
    echo "  (grpcurl not installed, skipping gRPC tests)"
    echo "  Install grpcurl: https://github.com/fullstorydev/grpcurl"
fi

# --- go-api (frontend / composition layer) ---

echo ""
echo "==> go-api"
check "GET /healthz" \
    "curl http://localhost:18080/healthz"

check "GET /readyz" \
    "curl http://localhost:18080/readyz"

check "POST /api/v1/orders (no auth)" \
    "curl -X POST http://localhost:18080/api/v1/orders" \
    "401"

check "POST /api/v1/orders (create order from seeded inventory)" \
    "curl -X POST http://localhost:18080/api/v1/orders -H 'Authorization: Bearer dev-token' -H 'Content-Type: application/json' -d '{\"item_id\":\"a0000000-0000-0000-0000-000000000001\",\"quantity\":2}'" \
    "201"

check "GET /api/v1/orders (list)" \
    "curl http://localhost:18080/api/v1/orders -H 'Authorization: Bearer dev-token'"

check "POST /api/v1/orders (insufficient stock)" \
    "curl -X POST http://localhost:18080/api/v1/orders -H 'Authorization: Bearer dev-token' -H 'Content-Type: application/json' -d '{\"item_id\":\"a0000000-0000-0000-0000-000000000002\",\"quantity\":9999}'" \
    "409"

check "POST /api/v1/orders (nonexistent item)" \
    "curl -X POST http://localhost:18080/api/v1/orders -H 'Authorization: Bearer dev-token' -H 'Content-Type: application/json' -d '{\"item_id\":\"does-not-exist\",\"quantity\":1}'" \
    "502"

# --- ui (static + reverse proxy with bearer injection) ---

echo ""
echo "==> ui"
check "GET / (landing HTML)" \
    "curl http://localhost:18082/"

check "GET /api/v1/inventory (proxied, bearer injected server-side)" \
    "curl http://localhost:18082/api/v1/inventory"

check "GET /api/v1/orders (proxied, bearer injected server-side)" \
    "curl http://localhost:18082/api/v1/orders"

check "GET /health/goapi (unauth readyz passthrough)" \
    "curl http://localhost:18082/health/goapi"

echo ""
if [ "$FAILED" -eq 0 ]; then
    echo "==> All smoke tests passed"
else
    echo "==> Some smoke tests failed"
    exit 1
fi
