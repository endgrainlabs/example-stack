# shellcheck shell=bash
# Shared machinery for the scenario scripts: flags, Forgejo access, the clone
# of the in-cluster repository, the Flux path switch, Flagsmith access and
# the flag switch, and the wait helper.
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
# The Flagsmith project setup.sh seeds, which holds the flags the services
# read. Its production environment is the one they read.
FLAGSMITH_PROJECT="example-stack"
# The three flags, one per service, all off at baseline.
FLAG_INVENTORY="inventory.expose_region"
FLAG_ORDERS="orders.forward_region"
FLAG_PRICING="pricing.regional_currency"
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

# Puts a working Forgejo access token in FORGEJO_TOKEN. The bring-up stores
# the token it minted in the forgejo-bootstrap Secret, and that one is reused
# while Forgejo still accepts it, so a stack that has run many scenarios does
# not accumulate a token per run. A missing Secret, or a token Forgejo no
# longer accepts, falls back to minting one through the command line inside
# the pod. The minted name carries the scenario and a timestamp: Forgejo
# rejects a duplicate name, and a demo.sh may be run more than once.
#
# Needs the port-forward open: the reused token is checked against the API
# before anything is cloned with it.
scenario_forgejo_token() {
    local token_output status

    FORGEJO_TOKEN=$(kubectl -n "${NAMESPACE}" get secret forgejo-bootstrap \
        -o jsonpath='{.data.token}' 2>/dev/null | base64 --decode 2>/dev/null || echo "")

    if [ -n "${FORGEJO_TOKEN}" ]; then
        # curl prints 000 itself when no connection is made, so no fallback:
        # one would print a second 000 after it.
        status=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 \
            -H "Authorization: token ${FORGEJO_TOKEN}" \
            "http://localhost:${FORGEJO_PF_PORT}/api/v1/user" 2>/dev/null || true)
        status="${status:-000}"
        if [ "${status}" = "200" ]; then
            echo "==> Reusing the Forgejo access token from the forgejo-bootstrap Secret"
            return 0
        fi
        echo "==> The stored Forgejo access token did not authenticate (${status}), generating one"
        FORGEJO_TOKEN=""
    fi

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
}

# Opens a port-forward to Forgejo and clones the in-cluster repository through
# it, so the overlay below can be pushed from the host.
scenario_open_forgejo() {
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

    scenario_forgejo_token

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
        -c commit.gpgsign=false commit -q -m "${SCENARIO_ID}: apply the scenario overlay"
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

# Answers a question about a Flagsmith API response. A copy of flagsmith_fact
# in scripts/setup.sh, which this file does not source; the modes are the
# same:
#
#   field KEY        one key of an object
#   find NAME KEY    one key of the first list entry whose name is NAME
#   first KEY        one key of the first list entry
#   names            the name of every list entry, one per line
#
# A list answer is either a bare array or a paginated object with "results".
# A boolean prints as true or false, the way the JSON spells it. Nothing found
# is a non-zero exit, so callers fall back with || echo "".
scenario_flagsmith_fact() {
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


def emit(value):
    if value is None:
        sys.exit(1)
    print(json.dumps(value) if isinstance(value, bool) else value)
    sys.exit(0)


if mode == "field":
    emit(doc.get(sys.argv[2]) if isinstance(doc, dict) else None)

items = doc.get("results", []) if isinstance(doc, dict) else doc
if mode == "names":
    for item in items:
        print(item["name"])
    sys.exit(0)

if mode == "first":
    emit(items[0].get(sys.argv[2]) if items else None)

for item in items:
    if item["name"] == sys.argv[2]:
        emit(item[sys.argv[3]])
sys.exit(1)
' "$@" 2>/dev/null
}

# A call to the Flagsmith admin API through the ingress, with the admin token
# attached. A body is passed in a variable built beforehand: bash 3.2
# brace-expands JSON written inside "$(...)".
scenario_flagsmith_api() {
    local method="$1"
    local path="$2"
    local body="${3:-}"
    local api="http://flagsmith.localhost:${INGRESS_PORT}/api/v1"
    if [ -n "${body}" ]; then
        curl -s --max-time 15 -X "${method}" \
            -H "Authorization: Token ${FLAGSMITH_TOKEN}" \
            -H "Content-Type: application/json" \
            -d "${body}" \
            "${api}${path}" || echo ""
    else
        curl -s --max-time 15 -X "${method}" \
            -H "Authorization: Token ${FLAGSMITH_TOKEN}" \
            "${api}${path}" || echo ""
    fi
}

# Reads the admin token and the production client key that setup.sh stored
# in the flagsmith-bootstrap Secret, and finds the seeded project. Flagsmith
# generates both at seed time, so the Secret is the only place they are kept.
scenario_open_flagsmith() {
    local projects

    echo "==> Reading the Flagsmith admin token and production key"
    FLAGSMITH_TOKEN=$(kubectl -n "${NAMESPACE}" get secret flagsmith-bootstrap \
        -o jsonpath='{.data.admin-token}' 2>/dev/null | base64 --decode 2>/dev/null || echo "")
    FLAGSMITH_PRODUCTION_KEY=$(kubectl -n "${NAMESPACE}" get secret flagsmith-bootstrap \
        -o jsonpath='{.data.production}' 2>/dev/null | base64 --decode 2>/dev/null || echo "")
    if [ -z "${FLAGSMITH_TOKEN}" ] || [ -z "${FLAGSMITH_PRODUCTION_KEY}" ]; then
        echo "ERROR: the flagsmith-bootstrap Secret in ${NAMESPACE} has no admin-token or production key;" >&2
        echo "       run scripts/setup.sh to seed Flagsmith" >&2
        exit 1
    fi

    projects=$(scenario_flagsmith_api GET /projects/)
    FLAGSMITH_PROJECT_ID=$(scenario_flagsmith_fact "${projects}" find "${FLAGSMITH_PROJECT}" id || echo "")
    if [ -z "${FLAGSMITH_PROJECT_ID}" ]; then
        echo "ERROR: could not find the Flagsmith project '${FLAGSMITH_PROJECT}'" >&2
        echo "       Flagsmith answered: ${projects}" >&2
        exit 1
    fi
}

# Finds a feature's state in the production environment, the one the services
# read, and sets FLAG_STATE_ID and FLAG_STATE_ENABLED (true or false). It sets
# globals rather than printing, so a caller runs it directly and not in a
# subshell. Needs scenario_open_flagsmith first.
FLAG_STATE_ID=""
FLAG_STATE_ENABLED=""
scenario_flag_state() {
    local name="$1"
    local features feature_id states

    features=$(scenario_flagsmith_api GET "/projects/${FLAGSMITH_PROJECT_ID}/features/")
    feature_id=$(scenario_flagsmith_fact "${features}" find "${name}" id || echo "")
    if [ -z "${feature_id}" ]; then
        echo "ERROR: Flagsmith has no feature '${name}' in the project '${FLAGSMITH_PROJECT}'" >&2
        echo "       Flagsmith answered: ${features}" >&2
        exit 1
    fi

    # The environment's own state for the feature, not a segment's or an
    # identity's: this endpoint lists only those.
    states=$(scenario_flagsmith_api GET "/environments/${FLAGSMITH_PRODUCTION_KEY}/featurestates/?feature=${feature_id}")
    FLAG_STATE_ID=$(scenario_flagsmith_fact "${states}" first id || echo "")
    FLAG_STATE_ENABLED=$(scenario_flagsmith_fact "${states}" first enabled || echo "")
    if [ -z "${FLAG_STATE_ID}" ]; then
        echo "ERROR: Flagsmith has no production state for feature '${name}'" >&2
        echo "       Flagsmith answered: ${states}" >&2
        exit 1
    fi
}

# Turns one feature's enabled bit on or off in the production environment.
# Only that bit: Flagsmith keeps a feature's value, which can be a string, a
# number, or JSON, apart from whether it is enabled, and this leaves the value
# alone. A feature already in that state is left alone too, so a re-run
# changes nothing.
scenario_set_flag_enabled() {
    local name="$1"
    local state="$2"
    local enabled body response

    case "${state}" in
        on)  enabled="true" ;;
        off) enabled="false" ;;
        *)
            echo "ERROR: scenario_set_flag_enabled takes on or off, not '${state}'" >&2
            exit 1 ;;
    esac

    scenario_flag_state "${name}"
    if [ "${FLAG_STATE_ENABLED}" = "${enabled}" ]; then
        echo "    '${name}' is already ${state} in production"
        return 0
    fi

    body='{"enabled":'"${enabled}"'}'
    response=$(scenario_flagsmith_api PUT "/environments/${FLAGSMITH_PRODUCTION_KEY}/featurestates/${FLAG_STATE_ID}/" "${body}")
    if [ "$(scenario_flagsmith_fact "${response}" field enabled || echo "")" != "${enabled}" ]; then
        echo "ERROR: could not turn feature '${name}' ${state} in production" >&2
        echo "       Flagsmith answered: ${response}" >&2
        exit 1
    fi
    echo "    '${name}' turned ${state} in production"
}

# Exits zero when all three flags are off in production, the baseline, and
# prints nothing: the callers say what the answer means for them.
scenario_flags_at_baseline() {
    local name
    for name in "${FLAG_PRICING}" "${FLAG_ORDERS}" "${FLAG_INVENTORY}"; do
        scenario_flag_state "${name}"
        if [ "${FLAG_STATE_ENABLED}" != "false" ]; then
            return 1
        fi
    done
    return 0
}

# Turns all three flags off, in the reverse of the order scenario 4 turns
# them on.
scenario_flags_restore_baseline() {
    scenario_set_flag_enabled "${FLAG_PRICING}" off
    scenario_set_flag_enabled "${FLAG_ORDERS}" off
    scenario_set_flag_enabled "${FLAG_INVENTORY}" off
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
            *[0-9]*)
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
