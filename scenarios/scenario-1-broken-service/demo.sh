#!/usr/bin/env bash
set -euo pipefail

# Scenario 1: broken service port
#
# Pushes a kustomize overlay to Forgejo that changes the go-grpc Service
# targetPort to 9099 (pod listens on 9090). Kube networking drops all gRPC
# traffic. go-grpc reports healthy, but go-api order creation fails with 502.
#
# Invoke with: bash scenarios/scenario-1-broken-service/demo.sh [--reset]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=../lib.sh disable=SC1091
source "${SCRIPT_DIR}/../lib.sh"

scenario_describe "scenario-1-broken-service" \
    "Point the go-grpc Service at a port nothing listens on."
scenario_parse_args "$@"

go_grpc_target_port() {
    kubectl -n "${NAMESPACE}" get svc go-grpc -o jsonpath='{.spec.ports[0].targetPort}'
}

# gRPC holds a persistent HTTP/2 connection, so changing the Service alone
# leaves existing traffic flowing. A restarted go-api dials the ClusterIP
# afresh and lands on the broken port.
restart_go_api() {
    echo "==> Restarting go-api so it re-dials through the Service"
    kubectl -n "${NAMESPACE}" rollout restart deployment/go-api
    kubectl -n "${NAMESPACE}" rollout status deployment/go-api --timeout=60s
}

# The script restarts go-api, so the counter starts from zero on a new pod and
# the old pod's series goes stale. The assertion reads the current pod's series
# only, and keeps creating orders while it polls so the 502s it counts are
# go-api's own and not a proxy's answer during the rollout.
errors_502_query() {
    local pod
    pod=$(kubectl -n "${NAMESPACE}" get pods -l app=go-api \
        -o jsonpath='{.items[0].metadata.name}')
    printf 'sum(goapi_http_requests_total{status="502",pod="%s"}) or vector(0)' "${pod}"
}

scenario_verify_break() {
    scenario_assert_eventually "go-grpc pod ready" "1" 60 scenario_ready_replicas go-grpc
    scenario_assert_eventually "order create returns 502" "502" 90 \
        scenario_order_status "${ITEM_EAST}" 2
    scenario_assert_eventually "order list returns 200" "200" 60 \
        scenario_get_status "http://goapi.localhost:${INGRESS_PORT}/api/v1/orders"
    scenario_assert_increased "goapi_http_requests_total{status=\"502\"} rising" \
        "$(errors_502_query)" 0 150 "scenario_order_status ${ITEM_EAST} 2"
}

scenario_verify_reset() {
    scenario_assert_eventually "order create returns 201" "201" 90 \
        scenario_order_status "${ITEM_EAST}" 2
}

if [ "${ACTION}" = "break" ]; then
    scenario_open_forgejo

    echo "==> Injecting scenario 1: broken go-grpc Service targetPort"
    scenario_push_overlay

    scenario_set_flux_path "./scenarios/${SCENARIO_ID}/overlay"
    scenario_wait_for "Service targetPort changed to 9099" "9099" go_grpc_target_port

    restart_go_api

    echo ""
    echo "==> Scenario 1 active. Expected symptoms:"
    echo "    - go-grpc pod: healthy (liveness/readiness pass)"
    echo "    - go-grpc Service: routes to wrong port (9099 vs 9090)"
    echo "    - go-api order creation: 502 (pricing lookup fails)"
    echo "    - go-api order reads: still work (no gRPC dependency)"
    echo "    - Prometheus: goapi_http_requests_total with status=502 rises"
    echo "    - Alert expected to fire after ~2m sustained error traffic: GoApiHighErrorRate"
    echo ""
    echo "    Try one request (returns 502):"
    echo "      curl -H 'Authorization: Bearer dev-token' -H 'Content-Type: application/json' \\"
    echo "           -d '{\"item_id\":\"a0000000-0000-0000-0000-000000000001\",\"quantity\":2}' \\"
    echo "           http://goapi.localhost:${INGRESS_PORT}/api/v1/orders"
    echo ""
    echo "    Generate sustained error traffic to trip the alert (~150s):"
    printf '%s\n' "      for i in \$(seq 1 150); do curl -s -o /dev/null -w '%{http_code}\\n' \\"
    echo "        -X POST -H 'Authorization: Bearer dev-token' -H 'Content-Type: application/json' \\"
    echo "        -d '{\"item_id\":\"a0000000-0000-0000-0000-000000000001\",\"quantity\":2}' \\"
    echo "        http://goapi.localhost:${INGRESS_PORT}/api/v1/orders; sleep 1; done"
    echo ""
    echo "    Check alert state:"
    echo "      curl -s http://prometheus.localhost:${INGRESS_PORT}/api/v1/alerts | python3 -c \\"
    echo "        'import json,sys; [print(a[\"labels\"][\"alertname\"],a[\"state\"]) for a in json.load(sys.stdin)[\"data\"][\"alerts\"]]'"
    echo ""
    echo "    Reset: bash scenarios/${SCENARIO_ID}/demo.sh --reset"

elif [ "${ACTION}" = "reset" ]; then
    scenario_set_flux_path "./k8s/apps/base"
    scenario_wait_for "Service targetPort restored to 9090" "9090" go_grpc_target_port

    restart_go_api

    echo "==> Scenario 1 cleared. Stack is back to healthy baseline."
    echo ""
    echo "    Note: if GoApiHighErrorRate was firing, it may take ~5-7 min to"
    echo "    clear. The rate([5m]) window retains errors for ~5 min and the"
    echo "    alert has for:2m on top. validate-stack.sh may report the alert"
    echo "    as firing until it settles."
fi

scenario_verify
