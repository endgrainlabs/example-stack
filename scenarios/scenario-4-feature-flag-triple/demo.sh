#!/usr/bin/env bash
set -euo pipefail

# Scenario 4: feature flag triple
#
# Models three feature flags in Flagsmith's production environment, one per
# service, that cause a functional regression only when all three are
# enabled: inventory.expose_region (rust-inventory adds a region derived from
# the warehouse), orders.forward_region (go-api passes that region to
# pricing), and pricing.regional_currency (go-grpc prices eu-west in EUR).
# With all three on, Gadget (the west warehouse item) is priced in EUR and
# go-api rejects the order with 422; Widget (east) keeps succeeding in USD.
#
# The demo enables them in the sequence 1, 2, 3 and, with --verify, checks
# the stack after each change. Any two flags are inert, so the other
# orderings end the same way; the demo does not walk them. An apply first restores the
# baseline, all three off, so a second apply replays the same walk.
#
# The change goes through Flagsmith's API, not Git: nothing is pushed to
# Forgejo and the Flux path is not touched. It leaves no entry in Flagsmith's
# audit log on this stack, whose free plan shows zero days of it. The flags'
# current state in the dashboard is the only record, with no history and no
# author. The failure is a 4xx, which no alert rule watches.
#
# Invoke with: bash scenarios/scenario-4-feature-flag-triple/demo.sh [--reset]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=../lib.sh disable=SC1091
source "${SCRIPT_DIR}/../lib.sh"

scenario_describe "scenario-4-feature-flag-triple" \
    "Three Flagsmith flags, one per service, cause a functional regression
only when all three are enabled: the west warehouse item is priced in EUR,
which go-api rejects with 422. The demo enables them in the sequence 1, 2, 3
and with --verify checks the stack between each change; any two flags are
inert, so the other orderings end the same way, and the demo does not walk
them. The change goes through Flagsmith's API: Forgejo and Flux show
nothing, Flagsmith's audit log on this stack shows no entry (the free plan's
audit visibility is zero days), and the dashboard shows only each flag's
current state, with no history and no author. No alert fires, because the
failure is a 4xx."
scenario_parse_args "$@"

# The services refresh their flags every ten seconds, so a step shows within
# this many seconds or it is not going to.
STEP_TIMEOUT=30
# Without --verify, the gap between flags, so each change is a separate
# moment in the logs and the dashboard.
STEP_PAUSE=2

# go-api is not restarted, so the sum over its pods keeps counting from the
# baseline taken just before the third flag goes on.
ERRORS_422_QUERY='sum(goapi_http_requests_total{status="422"}) or vector(0)'
ERRORS_422_BEFORE=""

# The region rust-inventory gives an item: the value, "none" when the field
# is absent, or the HTTP status when the request did not return an item.
inventory_region() {
    local body_file status region

    body_file=$(mktemp)
    status=$(curl -s -o "${body_file}" -w '%{http_code}' --max-time 15 \
        -H "Authorization: Bearer ${API_TOKEN}" \
        "http://rust.localhost:${INGRESS_PORT}/api/v1/inventory/$1" || echo "000")
    region=$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("region", "none"))' \
        <"${body_file}" 2>/dev/null || echo "")
    rm -f "${body_file}"

    if [ "${status}" = "200" ] && [ -n "${region}" ]; then
        printf '%s' "${region}"
    else
        printf 'status %s' "${status}"
    fi
}

# An order for the item succeeds, and in USD. A polling assertion runs its
# command in a subshell, so one more order fills ORDER_BODY for the currency.
assert_order_succeeds() {
    local label="$1"
    local item_id="$2"

    scenario_assert_eventually "order for ${label} returns 201" "201" "${STEP_TIMEOUT}" \
        scenario_order_status "${item_id}" 1
    scenario_order "${item_id}" 1
    scenario_check "the ${label} order is in USD" "yes" \
        "$(scenario_order_body_has '"currency":"USD"')"
}

# The stack is correct as a whole: both warehouses' items order in USD, both
# services are ready, and the Gadget item carries the region it should.
assert_stack_correct() {
    local gadget_region="$1"

    assert_order_succeeds "Widget" "${ITEM_EAST}"
    assert_order_succeeds "Gadget" "${ITEM_WEST}"
    scenario_assert_eventually "Gadget item region is ${gadget_region}" "${gadget_region}" \
        "${STEP_TIMEOUT}" inventory_region "${ITEM_WEST}"
    scenario_assert_eventually "go-api /readyz returns 200" "200" "${STEP_TIMEOUT}" \
        scenario_get_status "http://goapi.localhost:${INGRESS_PORT}/readyz"
    scenario_assert_eventually "rust-inventory /readyz returns 200" "200" "${STEP_TIMEOUT}" \
        scenario_get_status "http://rust.localhost:${INGRESS_PORT}/readyz"
}

scenario_verify_break() {
    scenario_assert_eventually "order for Gadget returns 422" "422" "${STEP_TIMEOUT}" \
        scenario_order_status "${ITEM_WEST}" 1
    scenario_order "${ITEM_WEST}" 1
    scenario_check "the 422 names the currency" "yes" \
        "$(scenario_order_body_has "unsupported currency: EUR")"
    assert_order_succeeds "Widget" "${ITEM_EAST}"
    scenario_assert_increased "goapi_http_requests_total{status=\"422\"} rising" \
        "${ERRORS_422_QUERY}" "${ERRORS_422_BEFORE}" 150 \
        "scenario_order_status ${ITEM_WEST} 1"
}

scenario_verify_reset() {
    assert_stack_correct "none"
}

scenario_open_flagsmith

# The assertions between steps run before scenario_verify, which is what
# normally reads the token.
if [ "${VERIFY}" -eq 1 ]; then
    API_TOKEN=$(scenario_api_token)
fi

if [ "${ACTION}" = "break" ]; then
    echo "==> Injecting scenario 4: three feature flags that only fail together"

    # The walk starts from the baseline, so a second apply replays it rather
    # than finding every flag on and checking a first-apply world.
    echo "==> Restoring the flag baseline before the walk"
    if scenario_flags_at_baseline; then
        echo "    All three flags are already off"
    else
        echo "    Not at baseline, turning all three flags off"
        scenario_flags_restore_baseline
    fi

    echo "==> Enabling the flags in the sequence 1, 2, 3"
    scenario_set_flag_enabled "${FLAG_INVENTORY}" on
    if [ "${VERIFY}" -eq 1 ]; then
        echo "==> Verifying the stack with ${FLAG_INVENTORY} on"
        assert_stack_correct "eu-west"
    else
        sleep "${STEP_PAUSE}"
    fi

    scenario_set_flag_enabled "${FLAG_ORDERS}" on
    if [ "${VERIFY}" -eq 1 ]; then
        echo "==> Verifying the stack with ${FLAG_INVENTORY} and ${FLAG_ORDERS} on"
        assert_stack_correct "eu-west"
    else
        sleep "${STEP_PAUSE}"
    fi

    if [ "${VERIFY}" -eq 1 ]; then
        ERRORS_422_BEFORE=$(scenario_prom_query "${ERRORS_422_QUERY}")
    fi
    scenario_set_flag_enabled "${FLAG_PRICING}" on

    echo ""
    echo "==> Scenario 4 active. The services pick the flags up within ten seconds."
    echo "    The regression needs all three flags enabled. The demo enabled them in"
    echo "    the sequence 1, 2, 3; any two are inert, so the other orderings end the"
    echo "    same way, and the demo does not walk them."
    echo ""
    echo "    Expected symptoms:"
    echo "    - rust-inventory: items carry a region (Gadget eu-west, Widget us-east)"
    echo "    - go-api + Widget (item 001, east, us-east): orders succeed (USD pricing)"
    echo "    - go-api + Gadget (item 002, west, eu-west): 422 unsupported currency: EUR"
    echo "    - all three services healthy, every readiness check passing"
    echo "    - Prometheus: goapi_http_requests_total with status=422 rises"
    echo "    - Alerts expected to fire: none."
    echo "        The goapi:http_error_rate recording rule matches {status=~\"5..\"} only,"
    echo "        so the 422s do not raise it and GoApiHighErrorRate stays quiet."
    echo ""
    echo "    Where the change shows:"
    echo "    - Forgejo: no commit. Flux: no change to any Kustomization."
    echo "    - Flagsmith's audit log: no entry on this stack; the free plan's audit"
    echo "      visibility is zero days."
    echo "    - Flagsmith's dashboard, the only record: each flag's current state in"
    echo "      the production environment of the example-stack project, with no"
    echo "      history and no author:"
    echo "        http://flagsmith.localhost:${INGRESS_PORT}/"
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
    echo "    See the region the first flag added:"
    echo "      curl -s -H 'Authorization: Bearer dev-token' \\"
    echo "        http://rust.localhost:${INGRESS_PORT}/api/v1/inventory/a0000000-0000-0000-0000-000000000002"
    echo ""
    echo "    Check alert state (expect no new firing alerts):"
    echo "      curl -s http://prometheus.localhost:${INGRESS_PORT}/api/v1/alerts | python3 -c \\"
    echo "        'import json,sys; [print(a[\"labels\"][\"alertname\"],a[\"state\"]) for a in json.load(sys.stdin)[\"data\"][\"alerts\"]]'"
    echo ""
    echo "    Reset: bash scenarios/${SCENARIO_ID}/demo.sh --reset"

elif [ "${ACTION}" = "reset" ]; then
    # Reset restores the baseline from whatever state the flags are in and
    # checks only the baseline: the states on the way down belong to no
    # scenario.
    echo "==> Clearing scenario 4: restoring the flag baseline"
    if scenario_flags_at_baseline; then
        echo "    All three flags are already off, the stack is at baseline"
    else
        echo "    Not at baseline, turning all three flags off"
    fi
    scenario_flags_restore_baseline

    echo "==> Scenario 4 cleared. The services pick the flags up within ten seconds."
    echo ""
    echo "    Note: this scenario fires none of the existing alerts, because"
    echo "    goapi:http_error_rate watches 5xx only, so there is nothing to"
    echo "    wait on. If alerts from a prior scenario are still settling,"
    echo "    validate-stack.sh reports them as firing until the rate([5m])"
    echo "    window and the for:2m clause have passed."
fi

scenario_verify
