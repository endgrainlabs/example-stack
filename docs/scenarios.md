# Failure scenarios

There are three reproducible failures, each a different class of distributed system
problem, each applied through the GitOps loop and reverted the same way, with
each failure known in advance.

The stack must be running first by executing `bash scripts/setup.sh`. Running `demo.sh`
for each scenario is idempotent.

## How a scenario is applied

Each scenario directory holds an `overlay/` (a kustomize overlay over
`k8s/apps/base`) and a `demo.sh` script to drive it. `demo.sh` clones the in-cluster
Forgejo repository, commits the overlay, pushes it, and patches the Flux `apps`
Kustomization to reconcile from the overlay path. The webhook triggers a Flux
reconciliation immediately.

`scenarios/lib.sh` has shared code between the scenarios' `demo.sh` scripts: flags,
the Forgejo token and port-forward, the clone, the overlay push, the Flux path switch, and
a wait helper. Each `demo.sh` contains only what is specific to its own failure.
`demo.sh` replaces its overlay directory in the clone, so a file dropped from a
scenario does not survive in Forgejo and a re-run with nothing to change pushes
nothing. A wait that times out fails.

Running `demo.sh` with `--reset` points the Kustomization path back at `./k8s/apps/base` and undoes
whatever else the scenario changed outside Git.

## Verifying a scenario

Running `demo.sh` with `--verify` asserts the outcome once the script has finished. With an apply it
asserts the symptoms listed under the scenario below; with `--reset` it asserts
the baseline. Each assertion prints PASS or FAIL the way `scripts/smoke-test.sh`
does, and a failed assertion exits `demo.sh` non-zero.

```sh
bash scenarios/scenario-1-broken-service/demo.sh --verify
bash scenarios/scenario-1-broken-service/demo.sh --reset --verify
```

The assertions reach the services and Prometheus through their respective
ingress and poll with a deadline, since a reconcile, a rollout, and a scrape
land seconds apart. The `go-grpc` health check needs a port-forward and
`grpcurl`, and logs a SKIP instead of failing when `grpcurl` is not installed.

Alerts are not asserted. Their `for` clauses put them minutes behind the
symptom, as described in the alerts section below.

Every scenario's `demo.sh` supports `--help`, and accepts `--cluster-name`, `--ingress-port`,
and `--kubeconfig-path` if the stack was brought up on values other than the
defaults. `--kubeconfig-path` defaults to `$HOME/.kube/<cluster-name>.yaml` like `setup.sh`.
The namespace is not a flag: every manifest in `k8s/apps/base` names `example-stack`.

## Scenario 1: broken service port

This is a Kubernetes networking misconfiguration.

The `go-grpc` Service `targetPort` is changed to 9099 while the container still
listens on 9090. Service routing drops every gRPC connection. The pod is
completely healthy: liveness and readiness pass, the process is fine, and its
own metrics show nothing wrong.

gRPC holds a persistent HTTP/2 connection, so changing the Service alone leaves
traffic that is already flowing untouched. The script restarts `go-api` so it
dials the Service afresh and lands on the broken port, the way a deploy or a
pod eviction would surface the fault in practice.

What a careful observer sees:

- `go-grpc` pod healthy, readiness passing.
- `go-api` order creation returning 502, because the pricing call fails.
- `go-api` order reads and health checks unaffected: they do not touch gRPC.
- `goapi_http_requests_total{status="502"}` rising in Prometheus.
- `GoApiHighErrorRate` firing after about two minutes of sustained errors,
  which takes a request loop like the one `demo.sh` prints; one request does
  not trip it.

Every health check in the cluster passes while the service is unreachable. Only
a request that crosses the Service boundary detects it.

```sh
bash scenarios/scenario-1-broken-service/demo.sh --verify
bash scenarios/scenario-1-broken-service/demo.sh --reset --verify
```

`--verify` asserts the `go-grpc` pod ready, order creation returning 502, order
reads returning 200, and the 502 counter rising. After a reset it asserts that
order creation returns 201.

## Scenario 2: bad migration

This is a schema migration that breaks application queries.

A goose migration renames the inventory table's `quantity` column to `qty`. The
overlay ships that migration in a ConfigMap and adds a second migration Job
that runs the stock `migrate` image with `-extra-dir` pointed at the mounted
ConfigMap, so the migration runs from the same binary the baseline Jobs use.
The migration is valid and the Job succeeds. `rust-inventory` queries still
name `quantity` and start failing.

What a careful observer sees:

- The `migrate-inventory-v2` Job succeeding. The deploy looks clean.
- `rust-inventory` returning 500 on inventory queries.
- `rust-inventory` readiness still passing, and a pod restarted during the
  scenario starting and failing the same way. `/readyz` runs `SELECT 1`, the
  startup check asks only that the inventory table exist, and neither names
  the column.
- `go-api` order creation returning 502, because the inventory lookup fails.
- `rustinventory_http_requests_total{status="500"}` rising, then, under
  sustained traffic, `RustInventoryHighErrorRate` and `GoApiHighErrorRate`
  firing.

The change that broke the system reports success. The failure appears in
`rust-inventory`, whose code did not change.

```sh
bash scenarios/scenario-2-bad-migration/demo.sh --verify
bash scenarios/scenario-2-bad-migration/demo.sh --reset --verify
```

`--verify` asserts the `migrate-inventory-v2` Job completed, the inventory list
returning 500, `rust-inventory` readiness still returning 200, and order
creation returning 502; it then restarts `rust-inventory` and asserts the new
pod is ready and still returns 500. After a reset it asserts the three seeded
items, order creation returning 201, and migration 003 recorded as not applied.

Reset asks `goose_db_version` whether migration 003 is applied and runs the
goose down migration only if it is, so a reset on a stack that never ran the
scenario, or a second reset in a row, leaves the seeded rows alone. A rollback
that fails fails the reset.

## Scenario 3: pricing assumption

This is a cross-service assumption the protocol does not capture.

`go-api` assumes every price is in USD and rejects anything else with 422. The
overlay sets `REGIONAL_PRICING=002=EUR` on `go-grpc`, which prices every item
whose identifier ends in `002` in EUR (Gadget, item `...0002`, the
`west` warehouse item). `go-grpc` holds no inventory and keys the rule on the
identifier alone. The proto allows any currency string, so `go-grpc` is correct
by its own contract and completely healthy.

This is a partial failure. Orders for Widget and Sprocket, both `east` and both
USD, still succeed. Only Gadget fails.

What a careful observer sees:

- `go-grpc` healthy, every call succeeding, every response valid against the
  proto.
- `go-api` orders for Widget and Sprocket succeeding.
- `go-api` orders for Gadget returning 422 with an unsupported currency error.
- `goapi_http_requests_total{status="422"}` rising for some item identifiers
  and not others.

Neither service violates its own contract. The overall error rate stays below
the alert threshold, and only a check of the specific item and currency
combination detects the failure.

```sh
bash scenarios/scenario-3-pricing-assumption/demo.sh --verify
bash scenarios/scenario-3-pricing-assumption/demo.sh --reset --verify
```

`--verify` asserts an order for Widget returning 201, an order for Gadget
returning 422 with a body naming the currency, and `go-grpc` health returning
`SERVING`. After a reset it asserts that an order for Gadget returns 201.

## Alerts take time to clear

The alert rules use a five minute rate window with a two minute `for` clause.
After a reset, an alert that was firing can take five to seven minutes to
clear, and `scripts/validate-stack.sh` reports it as firing until it does.

If an alert is expected to fire at steady state, add its name to
`EXPECTED_FIRING` in `scripts/validate-stack.sh` with a comment saying why.
