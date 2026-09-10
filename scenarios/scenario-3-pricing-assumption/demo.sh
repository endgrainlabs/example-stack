#!/usr/bin/env bash
set -euo pipefail

# Scenario 3: pricing assumption
#
# Sets REGIONAL_PRICING on go-grpc so items whose identifier ends in 002
# (Gadget, the west warehouse item) are priced in EUR. The proto contract
# allows any currency string, and go-grpc is healthy and correct from its own
# perspective. go-api assumes all prices are USD and rejects non-USD with 422.
#
# The failure is partial: ordering Widget (item 001, east) still works, and
# only ordering Gadget (item 002, west) returns 422.
#
# Invoke with: bash scenarios/scenario-3-pricing-assumption/demo.sh [--reset]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=../lib.sh disable=SC1091
source "${SCRIPT_DIR}/../lib.sh"

scenario_describe "scenario-3-pricing-assumption" \
    "Price the west warehouse item in EUR, which go-api rejects with 422."
scenario_parse_args "$@"

PRICING_RULE="002=EUR"

go_grpc_pricing_rule() {
    kubectl -n "${NAMESPACE}" get deploy go-grpc \
        -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="REGIONAL_PRICING")].value}'
}

restart_go_api() {
    echo "==> Restarting go-api so it re-dials the updated go-grpc"
    kubectl -n "${NAMESPACE}" rollout restart deployment/go-api
    kubectl -n "${NAMESPACE}" rollout status deployment/go-api --timeout=60s
}

scenario_verify_break() {
    scenario_assert_eventually "order for item 001 returns 201" "201" 90 \
        scenario_order_status "${ITEM_EAST}" 1
    scenario_assert_eventually "order for item 002 returns 422" "422" 90 \
        scenario_order_status "${ITEM_WEST}" 1
    # A polling assertion runs its command in a subshell, so the body it saw
    # does not survive it. One more order fills ORDER_BODY here: the status
    # alone does not say the currency was the reason.
    scenario_order "${ITEM_WEST}" 1
    scenario_check "the 422 names the currency" "yes" \
        "$(scenario_order_body_has "unsupported currency: EUR")"
    scenario_assert_grpc_serving
}

scenario_verify_reset() {
    scenario_assert_eventually "order for item 002 returns 201" "201" 90 \
        scenario_order_status "${ITEM_WEST}" 1
}

if [ "${ACTION}" = "break" ]; then
    scenario_open_forgejo

    echo "==> Injecting scenario 3: go-grpc regional pricing (EUR for the west warehouse)"
    scenario_push_overlay

    scenario_set_flux_path "./scenarios/${SCENARIO_ID}/overlay"
    scenario_wait_for "go-grpc REGIONAL_PRICING set to ${PRICING_RULE}" \
        "${PRICING_RULE}" go_grpc_pricing_rule

    kubectl -n "${NAMESPACE}" rollout status deployment/go-grpc --timeout=60s
    restart_go_api

    echo ""
    echo "==> Scenario 3 active. Expected symptoms:"
    echo "    - go-grpc: healthy, all RPCs succeed, proto-compliant"
    echo "    - go-api + Widget (item 001, east): orders succeed (USD pricing)"
    echo "    - go-api + Gadget (item 002, west): 422 unsupported currency EUR"
    echo "    - go-api + Sprocket (item 003, east): orders succeed (USD pricing)"
    echo "    - Prometheus: goapi_http_requests_total with status=422 for some orders"
    echo "    - Alerts expected to fire: none."
    echo "        The goapi:http_error_rate recording rule matches {status=~\"5..\"} only,"
    echo "        so the 422s do not raise it and GoApiHighErrorRate stays quiet. In"
    echo "        Prometheus the failure shows only as goapi_http_requests_total with"
    echo "        status=422 rising for item ...0002 while orders for the other two"
    echo "        items keep returning 201."
    echo ""
    echo "    Try (succeeds):"
    echo "      curl -s -H 'Authorization: Bearer dev-token' -H 'Content-Type: application/json' \\"
    echo "        -d '{\"item_id\":\"a0000000-0000-0000-0000-000000000001\",\"quantity\":1}' \\"
    echo "        http://goapi.localhost:${INGRESS_PORT}/api/v1/orders"
    echo ""
    echo "    Try (fails with 422):"
    echo "      curl -s -H 'Authorization: Bearer dev-token' -H 'Content-Type: application/json' \\"
    echo "        -d '{\"item_id\":\"a0000000-0000-0000-0000-000000000002\",\"quantity\":1}' \\"
    echo "        http://goapi.localhost:${INGRESS_PORT}/api/v1/orders"
    echo ""
    echo "    Check alert state (expect no new firing alerts):"
    echo "      curl -s http://prometheus.localhost:${INGRESS_PORT}/api/v1/alerts | python3 -c \\"
    echo "        'import json,sys; [print(a[\"labels\"][\"alertname\"],a[\"state\"]) for a in json.load(sys.stdin)[\"data\"][\"alerts\"]]'"
    echo ""
    echo "    Reset: bash scenarios/${SCENARIO_ID}/demo.sh --reset"

elif [ "${ACTION}" = "reset" ]; then
    scenario_set_flux_path "./k8s/apps/base"
    scenario_wait_for "go-grpc REGIONAL_PRICING removed" "" go_grpc_pricing_rule

    kubectl -n "${NAMESPACE}" rollout status deployment/go-grpc --timeout=60s
    restart_go_api

    echo "==> Scenario 3 cleared. Stack is back to healthy baseline."
    echo ""
    echo "    Note: this scenario fires none of the existing alerts, because"
    echo "    goapi:http_error_rate watches 5xx only, so there is nothing to"
    echo "    wait on. If alerts from a prior scenario are still settling,"
    echo "    validate-stack.sh reports them as firing until the rate([5m])"
    echo "    window and the for:2m clause have passed."
fi

scenario_verify
