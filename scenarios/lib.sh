# shellcheck shell=bash
# Shared machinery for the scenario scripts: flags, Forgejo access, the clone
# of the in-cluster repository, the Flux path switch, and the wait helper.
#
# Sourced by each demo.sh, never run on its own. A demo.sh sources this file,
# calls scenario_describe, and then scenario_parse_args "$@". A demo.sh that
# defines scenario_verify_break and scenario_verify_reset calls scenario_verify
# at the end, which runs the pair the action calls for when --verify was given.

# Most of what this file defines is read by the demo.sh that sources it, which
# is not visible from here.
# shellcheck disable=SC2034

# Configuration the scripts read after sourcing this file.
CLUSTER_NAME="example-stack"
# The namespace is fixed: every manifest in k8s/apps/base names it.
NAMESPACE="example-stack"
INGRESS_PORT="8090"
# Empty until the flags are parsed: the default follows the cluster name, the
# way setup.sh names the file it writes.
KUBECONFIG_PATH=""
ACTION="break"
VERIFY=0

FORGEJO_NS="forgejo"
FORGEJO_ORG="endgrainlabs"
FORGEJO_REPO="example-stack"
FORGEJO_ADMIN_USER="bootstrap"
FLUX_NS="flux-system"
# Local ports for the port-forwards: ports unlikely to be in use on the host.
FORGEJO_PF_PORT="13000"
GRPC_PF_PORT="19092"
# This file's own directory, so the verification helpers can reach the
# Prometheus response reader in scripts/.
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Synthetic committer identity for the scenario commits. Nothing sends mail.
SCENARIO_GIT_EMAIL="scenarios@example-stack.local"
SCENARIO_GIT_NAME="demo"

# Names the scenario for the usage text, the Forgejo token, and the commit.
scenario_describe() {
    SCENARIO_ID="$1"
    SCENARIO_SUMMARY="$2"
}

scenario_usage() {
    cat <<EOF
Usage: bash scenarios/${SCENARIO_ID}/demo.sh [--reset] [--verify] [config-flags...]

${SCENARIO_SUMMARY}

  --reset                   Revert the scenario and return the stack to its
                            healthy baseline
  --verify                  After applying or resetting, assert the documented
                            symptoms or the baseline, and exit non-zero if any
                            assertion fails
  --cluster-name=NAME       example-stack
  --ingress-port=PORT       8090
  --kubeconfig-path=PATH    \$HOME/.kube/<cluster-name>.yaml
  --help                    Show this message
EOF
}

scenario_parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --reset)             ACTION="reset" ;;
            --verify)            VERIFY=1 ;;
            --cluster-name=*)    CLUSTER_NAME="${1#*=}" ;;
            --ingress-port=*)    INGRESS_PORT="${1#*=}" ;;
            --kubeconfig-path=*) KUBECONFIG_PATH="${1#*=}" ;;
            --help|-h)           scenario_usage; exit 0 ;;
            *)
                echo "ERROR: unknown flag '$1'" >&2
                echo "" >&2
                scenario_usage >&2
                exit 1 ;;
        esac
        shift
    done

    KUBECONFIG_PATH="${KUBECONFIG_PATH:-${HOME}/.kube/${CLUSTER_NAME}.yaml}"
    export KUBECONFIG="${KUBECONFIG_PATH}"
}

scenario_cleanup() {
    if [ -n "${FORGEJO_PF_PID:-}" ]; then
        kill "${FORGEJO_PF_PID}" 2>/dev/null || true
        wait "${FORGEJO_PF_PID}" 2>/dev/null || true
    fi
    if [ -n "${GRPC_PF_PID:-}" ]; then
        kill "${GRPC_PF_PID}" 2>/dev/null || true
        wait "${GRPC_PF_PID}" 2>/dev/null || true
    fi
    if [ -n "${WORK_DIR:-}" ] && [ -d "${WORK_DIR}" ]; then
        rm -rf "${WORK_DIR}"
    fi
}
trap scenario_cleanup EXIT

# Generates a Forgejo access token through the command line inside the pod and
# opens a port-forward to Forgejo, so the clone below can reach it from the
# host. The token name carries the scenario and a timestamp: Forgejo rejects a
# duplicate name, and a demo.sh may be run more than once.
scenario_open_forgejo() {
    local token_output

    echo "==> Generating Forgejo access token"
    token_output=$(kubectl -n "${FORGEJO_NS}" exec deploy/forgejo -- \
        forgejo admin user generate-access-token \
        --username "${FORGEJO_ADMIN_USER}" \
        --scopes all \
        --token-name "${SCENARIO_ID}-$(date +%s)" 2>&1)
    FORGEJO_TOKEN=$(echo "${token_output}" | grep -oE '[a-f0-9]{30,}' | head -1)
    if [ -z "${FORGEJO_TOKEN}" ]; then
        echo "ERROR: failed to parse an access token from the Forgejo output:" >&2
        echo "${token_output}" >&2
        exit 1
    fi

    echo "==> Port-forwarding Forgejo"
    kubectl -n "${FORGEJO_NS}" port-forward "svc/forgejo" "${FORGEJO_PF_PORT}:3000" &>/dev/null &
    FORGEJO_PF_PID=$!
    # The forward answers within a second on an idle machine and several on a
    # busy one, so it is polled rather than waited for by a fixed sleep.
    for _ in $(seq 1 40); do
        if curl -s -o /dev/null --max-time 1 "http://localhost:${FORGEJO_PF_PORT}/" 2>/dev/null; then
            break
        fi
        sleep 0.5
    done

    WORK_DIR=$(mktemp -d)
    cd "${WORK_DIR}" || exit 1
    git clone -q \
        "http://${FORGEJO_ADMIN_USER}:${FORGEJO_TOKEN}@localhost:${FORGEJO_PF_PORT}/${FORGEJO_ORG}/${FORGEJO_REPO}.git" .
}

# Copies this scenario's overlay into the clone and pushes it. The overlay
# directory is replaced whole, so a file removed from the scenario does not
# survive in Forgejo, and a re-run with nothing to change pushes nothing.
scenario_push_overlay() {
    local overlay_dir="scenarios/${SCENARIO_ID}/overlay"

    rm -rf "${overlay_dir}"
    mkdir -p "scenarios/${SCENARIO_ID}"
    cp -R "${SCRIPT_DIR}/overlay" "${overlay_dir}"

    git -c user.email="${SCENARIO_GIT_EMAIL}" -c user.name="${SCENARIO_GIT_NAME}" add -A
    if git diff --cached --quiet; then
        echo "    Overlay already in the Forgejo repository, nothing to push"
        return 0
    fi
    git -c user.email="${SCENARIO_GIT_EMAIL}" -c user.name="${SCENARIO_GIT_NAME}" \
        commit -q -m "${SCENARIO_ID}: apply the scenario overlay"
    echo "==> Pushing to Forgejo"
    git push -q origin main
}

# Points the Flux apps Kustomization at a path and asks it to reconcile now.
# The webhook already makes a push reconcile, but a reset changes no files.
scenario_set_flux_path() {
    local path="$1"

    echo "==> Switching the Flux apps Kustomization path to ${path}"
    kubectl -n "${FLUX_NS}" patch kustomization apps --type merge \
        -p "{\"spec\":{\"path\":\"${path}\"}}"

    echo "==> Triggering Flux reconciliation"
    kubectl -n "${FLUX_NS}" annotate --overwrite kustomization apps \
        reconcile.fluxcd.io/requestedAt="$(date +%s)"
}

# Polls a command until it prints the expected value, for up to two minutes.
# A timeout is an error: the rest of a demo.sh describes a state the cluster
# would not be in.
scenario_wait_for() {
    local description="$1"
    local expected="$2"
    shift 2

    local i actual
    for i in $(seq 1 60); do
        actual=$("$@" 2>/dev/null || echo "")
        if [ "${actual}" = "${expected}" ]; then
            echo "    ${description}"
            return 0
        fi
        sleep 2
    done

    echo "ERROR: timed out after 2m waiting for ${description}" >&2
    return 1
}

# --- Verification ----------------------------------------------------------
#
# --verify asserts what docs/scenarios.md says the stack does, once the script
# has finished: the symptoms after an apply, the baseline after a reset. Each
# assertion prints PASS or FAIL the way scripts/smoke-test.sh does, and one
# failure exits the script non-zero. Alerts are not asserted: their for clauses
# make them minutes slow, which docs/scenarios.md records.

VERIFY_FAILED=0
# Set by scenario_verify and scenario_order, and read by the assertions.
API_TOKEN=""
ORDER_STATUS=""
ORDER_BODY=""

# The seeded inventory items the assertions order: 001 is the east warehouse
# item, 002 the west one, the one scenario 3 prices in EUR.
ITEM_EAST="a0000000-0000-0000-0000-000000000001"
ITEM_WEST="a0000000-0000-0000-0000-000000000002"

# The bearer token comes from the Secret, so the checks use whatever the stack
# was installed with.
scenario_api_token() {
    kubectl -n "${NAMESPACE}" get secret example-secrets \
        -o jsonpath='{.data.api-token}' | base64 --decode
}

scenario_check() {
    local description="$1"
    local expected="$2"
    local actual="$3"

    if [ "${actual}" = "${expected}" ]; then
        echo "  PASS  ${description} (${actual})"
    else
        echo "  FAIL  ${description} (got ${actual}, expected ${expected})"
        VERIFY_FAILED=1
    fi
}

# Polls a command until it prints the expected value or the deadline passes,
# then reports what it found. A rollout, a Flux reconcile, and a reconnect land
# seconds apart, so an assertion taken once is a race.
scenario_assert_eventually() {
    local description="$1"
    local expected="$2"
    local timeout="$3"
    shift 3

    local deadline actual
    deadline=$(( $(date +%s) + timeout ))
    while :; do
        actual=$("$@" 2>/dev/null || echo "")
        if [ "${actual}" = "${expected}" ]; then
            break
        fi
        if [ "$(date +%s)" -ge "${deadline}" ]; then
            break
        fi
        sleep 3
    done
    scenario_check "${description}" "${expected}" "${actual}"
}

# Polls a Prometheus query until its value exceeds a baseline taken earlier.
# Counters move on a scrape interval, so this needs a longer deadline than a
# request does. An optional fifth argument is a command run before each poll,
# so the traffic that moves the counter keeps flowing while Prometheus catches
# up; without it a single early request can be the only one, and if a proxy
# answered that request the service's own counter never moves.
scenario_assert_increased() {
    local description="$1"
    local query="$2"
    local before="$3"
    local timeout="$4"
    local traffic="${5:-}"

    local deadline actual
    deadline=$(( $(date +%s) + timeout ))
    while :; do
        if [ -n "${traffic}" ]; then
            ${traffic} >/dev/null 2>&1 || true
        fi
        actual=$(scenario_prom_query "${query}")
        # A reading that is not a number is a failed query, not a counter
        # value: awk compares "error" with 0 as strings and calls it a rise.
        case "${actual}" in
            ''|*[!0-9.eE+-]*) ;;
            *)
                if awk -v a="${actual}" -v b="${before}" 'BEGIN { exit !(a > b) }' 2>/dev/null; then
                    echo "  PASS  ${description} (${before} to ${actual})"
                    return 0
                fi ;;
        esac
        if [ "$(date +%s)" -ge "${deadline}" ]; then
            break
        fi
        sleep 5
    done
    echo "  FAIL  ${description} (still ${actual}, was ${before})"
    VERIFY_FAILED=1
}

# Runs an instant query through the Prometheus ingress and prints the value.
# Wrap a counter sum in "or vector(0)" so a series that does not exist yet
# reads as zero instead of as an empty result.
scenario_prom_query() {
    local query="$1"
    local response

    response=$(curl -s --max-time 10 --get --data-urlencode "query=${query}" \
        "http://prometheus.localhost:${INGRESS_PORT}/api/v1/query" || echo "")
    printf '%s' "${response}" | python3 "${LIB_DIR}/../scripts/promjson.py" query-value 2>/dev/null || echo "error"
}

# Creates an order through the go-api ingress. Sets ORDER_STATUS and
# ORDER_BODY: the scenarios differ on the status, and scenario 3 also on what
# the body says.
scenario_order() {
    local item_id="$1"
    local quantity="${2:-1}"
    local body_file

    body_file=$(mktemp)
    ORDER_STATUS=$(curl -s -o "${body_file}" -w '%{http_code}' --max-time 15 \
        -X POST \
        -H "Authorization: Bearer ${API_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "{\"item_id\":\"${item_id}\",\"quantity\":${quantity}}" \
        "http://goapi.localhost:${INGRESS_PORT}/api/v1/orders" || echo "000")
    ORDER_BODY=$(cat "${body_file}")
    rm -f "${body_file}"
}

# The status of an order create, for the polling assertions.
scenario_order_status() {
    scenario_order "$1" "${2:-1}"
    printf '%s' "${ORDER_STATUS}"
}

# Says whether the last order response body contained a string, so a status
# assertion can be paired with the reason the service gave for it.
scenario_order_body_has() {
    if printf '%s' "${ORDER_BODY}" | grep -q "$1"; then
        printf 'yes'
    else
        printf 'no (%s)' "$(printf '%s' "${ORDER_BODY}" | tr '\n' ' ')"
    fi
}

# The status of a GET through the ingress, with the bearer token attached.
scenario_get_status() {
    curl -s -o /dev/null -w '%{http_code}' --max-time 15 \
        -H "Authorization: Bearer ${API_TOKEN}" "$1" || echo "000"
}

# Lists inventory through the rust-inventory ingress and prints the count of
# items, or the HTTP status when the request did not return a list.
scenario_inventory_count() {
    local body_file status count

    body_file=$(mktemp)
    status=$(curl -s -o "${body_file}" -w '%{http_code}' --max-time 15 \
        -H "Authorization: Bearer ${API_TOKEN}" \
        "http://rust.localhost:${INGRESS_PORT}/api/v1/inventory" || echo "000")
    count=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["count"])' <"${body_file}" 2>/dev/null || echo "")
    rm -f "${body_file}"

    if [ -n "${count}" ]; then
        printf '%s' "${count}"
    else
        printf 'status %s' "${status}"
    fi
}

# Deployment readiness, which is what says a pod is healthy while a Service
# in front of it is not.
scenario_ready_replicas() {
    kubectl -n "${NAMESPACE}" get deploy "$1" -o jsonpath='{.status.readyReplicas}'
}

# go-grpc is not exposed through the ingress, so its health call needs a
# port-forward and grpcurl. Without grpcurl the check says so and passes, the
# way scripts/smoke-test.sh treats its gRPC checks.
scenario_assert_grpc_serving() {
    if ! command -v grpcurl >/dev/null 2>&1; then
        echo "  SKIP  go-grpc health (grpcurl not installed)"
        return 0
    fi

    kubectl -n "${NAMESPACE}" port-forward "svc/go-grpc" "${GRPC_PF_PORT}:9090" &>/dev/null &
    GRPC_PF_PID=$!
    sleep 2

    local output
    output=$(grpcurl -plaintext "localhost:${GRPC_PF_PORT}" echo.v1.EchoService/Health 2>&1 || echo "")
    kill "${GRPC_PF_PID}" 2>/dev/null || true
    wait "${GRPC_PF_PID}" 2>/dev/null || true
    GRPC_PF_PID=""

    if printf '%s' "${output}" | grep -q "SERVING"; then
        scenario_check "go-grpc health" "SERVING" "SERVING"
    else
        scenario_check "go-grpc health" "SERVING" "$(printf '%s' "${output}" | tr '\n' ' ')"
    fi
}

# Runs the assertions for the action the script just took. Each demo.sh defines
# scenario_verify_break and scenario_verify_reset.
scenario_verify() {
    if [ "${VERIFY}" -ne 1 ]; then
        return 0
    fi

    API_TOKEN=$(scenario_api_token)
    echo ""
    if [ "${ACTION}" = "reset" ]; then
        echo "==> Verifying the baseline"
        scenario_verify_reset
    else
        echo "==> Verifying the scenario symptoms"
        scenario_verify_break
    fi

    echo ""
    if [ "${VERIFY_FAILED}" -eq 0 ]; then
        echo "==> All assertions passed"
    else
        echo "==> Some assertions failed"
        exit 1
    fi
}
