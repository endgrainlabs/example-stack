#!/usr/bin/env bash
set -euo pipefail

# Scenario 2: bad migration
#
# Ships migration 003, which renames the inventory table's "quantity" column
# to "qty", in a ConfigMap that a second migration Job applies through the
# stock migrate image's -extra-dir. The migration succeeds, but
# rust-inventory's queries reference "quantity" and start returning 500s.
# go-api order creation fails because inventory lookups fail.
#
# Invoke with: bash scenarios/scenario-2-bad-migration/demo.sh [--reset]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=../lib.sh disable=SC1091
source "${SCRIPT_DIR}/../lib.sh"

scenario_describe "scenario-2-bad-migration" \
    "Rename the inventory quantity column out from under rust-inventory."
scenario_parse_args "$@"

# The image the migration Jobs run, under the name the cluster nodes use.
MIGRATE_IMAGE="example-stack-registry:5000/example-stack/migrate:latest"
# The ConfigMap the overlay generates, holding migration 003.
MIGRATIONS_CONFIGMAP="scenario-2-migrations"
EXTRA_DIR="/extra-migrations"

migrate_job_succeeded() {
    kubectl -n "${NAMESPACE}" get job migrate-inventory-v2 -o jsonpath='{.status.succeeded}'
}

psql_inventory() {
    kubectl -n "${NAMESPACE}" exec deploy/postgres -- \
        psql -U postgres -d inventory -tAc "$1" | tr -d '[:space:]'
}

# The rollback runs the same migrate image the Jobs use, with the scenario
# ConfigMap mounted where -extra-dir points, so the scenario needs no image of
# its own.
rollback_003() {
    kubectl -n "${NAMESPACE}" run migrate-rollback \
        --rm -i --restart=Never \
        --image="${MIGRATE_IMAGE}" \
        --override-type=merge \
        --overrides="{
            \"spec\": {
                \"containers\": [{
                    \"name\": \"migrate-rollback\",
                    \"image\": \"${MIGRATE_IMAGE}\",
                    \"args\": [\"-dir\", \"inventory\", \"-extra-dir\", \"${EXTRA_DIR}\", \"down\"],
                    \"env\": [{
                        \"name\": \"DATABASE_URL\",
                        \"valueFrom\": {\"secretKeyRef\": {\"name\": \"example-secrets\", \"key\": \"postgres-dsn\"}}
                    }],
                    \"volumeMounts\": [{
                        \"name\": \"extra-migrations\",
                        \"mountPath\": \"${EXTRA_DIR}\",
                        \"readOnly\": true
                    }]
                }],
                \"volumes\": [{
                    \"name\": \"extra-migrations\",
                    \"configMap\": {\"name\": \"${MIGRATIONS_CONFIGMAP}\"}
                }]
            }
        }"
}

# The newest goose_db_version row for version 3 says whether it is applied
# now: goose writes one row per apply and per rollback. A stack that never ran
# the scenario has no table at all.
migration_003_applied() {
    local goose_table
    goose_table=$(psql_inventory "SELECT to_regclass('public.goose_db_version')")
    if [ -z "${goose_table}" ]; then
        echo "f"
        return 0
    fi
    psql_inventory \
        "SELECT COALESCE((SELECT is_applied FROM goose_db_version WHERE version_id = 3 ORDER BY id DESC LIMIT 1), false)"
}

scenario_verify_break() {
    scenario_assert_eventually "migrate-inventory-v2 Job completed" "1" 90 migrate_job_succeeded
    scenario_assert_eventually "inventory list returns 500" "status 500" 90 scenario_inventory_count
    scenario_assert_eventually "rust-inventory /readyz returns 200" "200" 60 \
        scenario_get_status "http://rust.localhost:${INGRESS_PORT}/readyz"
    scenario_assert_eventually "order create returns 502" "502" 90 \
        scenario_order_status "${ITEM_EAST}" 2

    # A pod restarted mid-scenario starts, because the startup check asks only
    # that the table exist, and then fails per request like the one it replaced.
    restart_rust_inventory
    scenario_assert_eventually "restarted rust-inventory /readyz returns 200" "200" 60 \
        scenario_get_status "http://rust.localhost:${INGRESS_PORT}/readyz"
    scenario_assert_eventually "restarted rust-inventory still returns 500" "status 500" 60 \
        scenario_inventory_count
}

scenario_verify_reset() {
    scenario_assert_eventually "inventory list returns the three seeded items" "3" 120 \
        scenario_inventory_count
    scenario_assert_eventually "order create returns 201" "201" 90 \
        scenario_order_status "${ITEM_EAST}" 2
    # A second reset reads this same row, finds 003 unapplied, and rolls
    # nothing back, which is what leaves the seeded rows alone.
    scenario_assert_eventually "migration 003 not applied" "f" 30 migration_003_applied
}

restart_rust_inventory() {
    echo "==> Restarting rust-inventory"
    kubectl -n "${NAMESPACE}" rollout restart deployment/rust-inventory
    kubectl -n "${NAMESPACE}" rollout status deployment/rust-inventory --timeout=60s
}

if [ "${ACTION}" = "break" ]; then
    scenario_open_forgejo

    echo "==> Injecting scenario 2: breaking inventory migration"
    scenario_push_overlay

    scenario_set_flux_path "./scenarios/${SCENARIO_ID}/overlay"
    scenario_wait_for "migrate-inventory-v2 Job completed" "1" migrate_job_succeeded

    echo ""
    echo "==> Scenario 2 active. Expected symptoms:"
    echo "    - migrate-inventory-v2 Job: succeeds (migration runs fine)"
    echo "    - rust-inventory: 500 on inventory queries (column 'quantity' no longer exists)"
    echo "    - rust-inventory readiness: still passing, and a restarted pod comes up"
    echo "      and fails the same way: /readyz runs SELECT 1, the startup check asks"
    echo "      only that the table exist, and neither names the column"
    echo "    - go-api order creation: 502 (inventory lookup fails)"
    echo "    - Prometheus: rustinventory_http_requests_total with status=500 rises"
    echo "    - Alerts expected to fire after ~2m sustained traffic:"
    echo "        RustInventoryHighErrorRate (5xx on inventory endpoints)"
    echo "        GoApiHighErrorRate (502 on order creation fanning out)"
    echo ""
    echo "    Try one request (returns 500):"
    echo "      curl -H 'Authorization: Bearer dev-token' http://rust.localhost:${INGRESS_PORT}/api/v1/inventory"
    echo ""
    echo "    Generate sustained error traffic to trip the alerts (~150s):"
    printf '%s\n' "      for i in \$(seq 1 150); do curl -s -o /dev/null -w '%{http_code}\\n' \\"
    echo "        -H 'Authorization: Bearer dev-token' \\"
    echo "        http://rust.localhost:${INGRESS_PORT}/api/v1/inventory; sleep 1; done"
    echo ""
    echo "    Check alert state:"
    echo "      curl -s http://prometheus.localhost:${INGRESS_PORT}/api/v1/alerts | python3 -c \\"
    echo "        'import json,sys; [print(a[\"labels\"][\"alertname\"],a[\"state\"]) for a in json.load(sys.stdin)[\"data\"][\"alerts\"]]'"
    echo ""
    echo "    Reset: bash scenarios/${SCENARIO_ID}/demo.sh --reset"

elif [ "${ACTION}" = "reset" ]; then
    # The rollback runs before the Flux path moves back to the base: the
    # migration SQL lives in a ConfigMap the overlay ships, and switching the
    # path first prunes it.
    echo "==> Checking whether migration 003 is applied"
    if [ "$(migration_003_applied)" = "t" ]; then
        echo "==> Rolling back migration 003 (qty back to quantity)"
        rollback_003
    else
        echo "    Migration 003 is not applied, nothing to roll back"
    fi

    scenario_set_flux_path "./k8s/apps/base"
    kubectl -n "${FLUX_NS}" wait --for=condition=Ready --timeout=2m kustomization/apps

    echo "==> Scenario 2 cleared. Stack is back to healthy baseline."
    echo ""
    echo "    If RustInventoryHighErrorRate or GoApiHighErrorRate were firing, they"
    echo "    may take ~5-7 min to clear. The rate([5m]) window retains errors for"
    echo "    ~5 min and the alerts have for:2m on top. validate-stack.sh may"
    echo "    report alerts as firing until they settle."
fi

scenario_verify
