# Services

This describes each service in the stack, its endpoints, what it
depends on, and how it is built. The cluster's wiring is described
in [topology.md](topology.md).

Every service authenticates with the bearer token `dev-token`. It is a
demo-only value set in `k8s/apps/base/secrets.yaml`.

## go-api

Implemented in Go, HTTP, PostgreSQL. It is the frontend service and the
composition layer. It creates orders by validating stock against
`rust-inventory`, fetching pricing from `go-grpc`, checking the
currency, and writing the order to PostgreSQL.

`go-api` runs on port 8080 by default.

| Endpoint | Auth | Description |
|---|---|---|
| `GET /healthz` | No | Liveness. Always returns `{"status": "ok"}` |
| `GET /readyz` | No | Readiness. Checks database connectivity |
| `GET /metrics` | No | Prometheus metrics: request counts, latency histograms, an orders gauge |
| `GET /api/v1/orders` | Yes | List orders |
| `POST /api/v1/orders` | Yes | Create an order. Body `{"item_id": "...", "quantity": N}` |
| `GET /api/v1/orders/{id}` | Yes | Get an order by identifier |
| `DELETE /api/v1/orders/{id}` | Yes | Delete an order by identifier |

`go-api` depends on `http://rust-inventory:8081` for inventory stock,
`go-grpc:9090` for pricing, and the `orders` database.

`go-api` reads one feature flag, `orders.forward_region`. While it is on
and the inventory item carries a `region`, the pricing request includes
that region. While it is off, or the item carries none, the request never
names a region. The USD check does not change with it.

Notable status codes

- 401 without a token
- 409 when stock is insufficient
- 422 when pricing returns a currency other than USD
- 502 when a backend call fails.

What a careful observer can check

- Health and readiness return 200 while the database is reachable.
- Order creation exercises the whole call graph (inventory lookup,
pricing, and database writes)
- Insufficient stock returns 409, an unknown item returns 502, a
missing token returns 401.
- When `go-grpc` is unreachable, order creation returns 502 while
order reads keep working.
- Slow responses from `rust-inventory` raise `go-api` latency.

Deliberate and known weaknesses

- no pagination on the list endpoint
- no circuit breaking on backend calls
- orders may reference inventory items which were deleted afterwards.

Creating an order also never decrements inventory quantity. `go-api`
only reads `rust-inventory` to check availability and never writes to
it, so the same item can be ordered without limit. The UI reloads the
inventory table after each order as though the quantity had changed,
and it has not.

## go-grpc

Implemented in Go, gRPC and supports pricing and echo. The service is
stateless - a price is derived from the item identifier, so the same
item always gets the same price.

`go-grpc` runs on port 9090 for gRPC by default and port 9091 for Prometheus
metrics over HTTP.

| Remote procedure call | Auth | Description |
|---|---|---|
| `echo.v1.EchoService/Health` | No | Returns `SERVING` and the process uptime |
| `echo.v1.EchoService/Echo` | Yes | Echoes the message with a timestamp |
| `pricing.v1.PricingService/GetPrice` | Yes | Returns a price for an item identifier and quantity |

Authentication uses the `authorization: Bearer dev-token` metadata key.
Reflection is enabled, so a client can discover the services without
the proto files. The protos are `go-grpc/proto/echo.proto` and
`go-grpc/proto/pricing.proto`. A panic in a handler is recovered by the
go-grpc-middleware interceptor and answered with an `Internal` error for
that request, with the stack in the log, so a bug reached through a
request shows up as an error rate rather than as a restarted process.

`REGIONAL_PRICING` is read once at startup: a comma-separated list of
`SUFFIX=CURRENCY` rules, for example `002=EUR`, which prices every item
whose identifier ends in that suffix in that currency. It is empty by
default, so every price is USD. Scenario 3 sets it, which breaks
`go-api`'s USD assumption.

`GetPrice` takes an optional `region`. `go-grpc` reads one feature flag,
`pricing.regional_currency`: while it is on, a request whose region is
`eu-west` is priced in EUR, whatever `REGIONAL_PRICING` says. While it
is off, or the request names no region or another one, the currency is
what `REGIONAL_PRICING` gives.

What a careful observer can check

- Health returns `SERVING`, and uptime increases between calls, which
shows the process did not restart.
- `GetPrice` is consistent for the same item identifier.
- A call without metadata returns `UNAUTHENTICATED`; an empty item
identifier or a non-positive quantity returns `INVALID_ARGUMENT`.

Deliberate and known weaknesses

- no connection draining (in-flight calls are dropped when the pod
restarts)
- no request size limits.

## rust-inventory

Implemented in Rust, HTTP, PostgreSQL. This holds inventory stock
levels. `go-api` queries it when creating an order.

`rust-inventory` runs on port 8081 by default and uses the `inventory` database.

| Endpoint | Auth | Description |
|---|---|---|
| `GET /healthz` | No | Liveness. Always returns `{"status": "ok"}` |
| `GET /readyz` | No | Readiness. Returns 200 with `{"status": "ready", "database": "connected"}` or 503 |
| `GET /metrics` | No | Prometheus metrics through actix-web-prom |
| `GET /api/v1/inventory` | Yes | List items |
| `POST /api/v1/inventory` | Yes | Create an item. Body `{"name": "...", "quantity": N, "warehouse": "..."}` |
| `GET /api/v1/inventory/{id}` | Yes | Get an item by identifier |
| `DELETE /api/v1/inventory/{id}` | Yes | Delete an item by identifier |

The schema (created by the migration Job, not by the service)

```sql
CREATE TABLE inventory (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    name TEXT NOT NULL,
    quantity INTEGER NOT NULL DEFAULT 0,
    warehouse TEXT NOT NULL,
    created_at TIMESTAMP NOT NULL DEFAULT NOW(),
    CONSTRAINT quantity_non_negative CHECK (quantity >= 0)
);
```

Seed data, also from the migration Job

| Identifier | Name | Quantity | Warehouse |
|---|---|---|---|
| `a0000000-0000-0000-0000-000000000001` | Widget | 100 | east |
| `a0000000-0000-0000-0000-000000000002` | Gadget | 50 | west |
| `a0000000-0000-0000-0000-000000000003` | Sprocket | 200 | east |

`rust-inventory` reads one feature flag, `inventory.expose_region`.
While it is on, each item in the list and get responses carries a
`region` derived from its warehouse: `east` is `us-east` and `west` is
`eu-west`, and a warehouse with neither gets no field. While it is off
the responses are byte for byte what they are without the flag. The
create response never carries one.

What a careful observer can check

- Health returns 200 whatever the database is doing; readiness returns
200 only while the database is connected.
- The seed data is present once the migration Job completes.
- The full lifecycle: create, get, list, delete, then confirm a 404.
- The `quantity >= 0` constraint is enforced.
- Deleting a seeded item makes `go-api` order creation fail for that item.

Deliberate and known weaknesses

- no connection pooling, so requests contend on a single database connection
- no pagination on the list endpoint.

## ui

This is an nginx container serving a single page of static HTML, CSS,
and JavaScript with no build step, plus a reverse proxy that injects
the bearer token server-side so the browser never holds a credential.
The proxy configuration is a template - the image's envsubst step fills
`${API_TOKEN}` in from the Secret when the container starts, so the
token is held in one place.

`ui` is served on port 80 by default, published at `http://ui.localhost:8090/`.

| Path | Description |
|---|---|
| `/` | The order-management page |
| `/api/v1/orders*` | Proxied to `go-api` with the token injected |
| `/api/v1/inventory*` | Proxied to `rust-inventory` with the token injected |
| `/health/goapi`, `/health/rust` | Proxied to each service's `/readyz` for the status indicator |

If you apply a failure scenario and reload the page: the banner and the
per-action error messages show exactly what the API returned, in the
form a user would see it.

## landing page

This is an nginx container serving one static page from a ConfigMap at
`http://example-stack.localhost:8090/`, linking to every service and
infrastructure interface with the ports this stack uses.

## PostgreSQL and the migrations

There is a single PostgreSQL 17 Deployment that holds every database in the
stack. Its manifests are in `k8s/infra/postgres`, and the `infra`
Kustomization reconciles them with the `example-stack` namespace and
Flagsmith, ahead of the services and their migration Jobs, which the
`apps` Kustomization reconciles. It has its own `postgres` Secret rather
than a key in `example-secrets`, which belongs to `apps`: the database
comes up before that Secret exists. `inventory` is created by the image's own initialization; `orders` and
`flagsmith` are created by an initialization script mounted from a ConfigMap,
which the image runs only against an empty data directory, so they appear on
a fresh volume and not on a restart. Data is on a 100Mi local-path volume,
which survives pod restarts and `k3d cluster stop` and is lost on cluster
delete.

Schema and seed data are applied by Kubernetes Jobs, not by services:
[goose](https://github.com/pressly/goose) for the two service databases,
Flagsmith's own Django migrations for its. The services expect the schema
to exist and fail if it does not.

| Job | Database | Description |
|---|---|---|
| `migrate-inventory-v1` | `inventory` | Creates the inventory table and seeds three items |
| `migrate-orders-v1` | `orders` | Creates the orders table |
| `migrate-flagsmith-v1` | `flagsmith` | Runs Flagsmith's own Django migrations from its image, not goose |

The migration SQL lives in `migrate/migrations/inventory/` and
`migrate/migrations/orders/`, embedded into the `migrate` binary
through Go's `embed` package. `-extra-dir PATH` runs the SQL files in a
filesystem directory after the embedded set, against the same
`goose_db_version` table, which is how scenario 2 adds a migration
without a variant image. Job names carry a version suffix: when
migration content changes, the suffix is bumped, so Flux creates a new
Job and leaves the completed one alone. Completed Jobs stay: a TTL would
delete them, and Flux would re-create and re-run them on its next
reconcile.

On a fresh cluster the services may restart once or twice while the
migration Jobs run. Those restarts show up in
`kube_pod_container_status_restarts_total`.

## Flagsmith

Flagsmith is a self-hosted feature flag server, deployed by Flux from
`k8s/infra/flagsmith` into its own `flagsmith` namespace, as part of the
`infra` Kustomization. It is the unified image, so one container serves both
the API and the web interface on port 8000, reachable at
`http://flagsmith.localhost:8090/`. Its schema lives in the `flagsmith`
database in the shared PostgreSQL and is applied by the
`migrate-flagsmith-v1` Job, not by the server.

| Endpoint | Auth | Description |
|---|---|---|
| `GET /health/liveness/` | No | Liveness. Returns `{"status": "ok"}` without touching the database |
| `GET /health/readiness/` | No | Readiness. 200 while the database is reachable and no migration is outstanding, 500 otherwise |
| `GET /metrics/` on port 9100 | No | Prometheus metrics, from a second HTTP server in the same process. A `ServiceMonitor` registers it |
| `/api/v1/...` | Yes | The Flagsmith REST API. `Authorization: Token <key>` for the admin API, `X-Environment-Key: <key>` for the SDK endpoints |

`scripts/setup.sh` seeds it after Flux has reconciled it and before the
services are applied: a bootstrap account, an organization and a project both
named `example-stack`, exactly two environments, `staging` and `production`,
a server-side key named `example-stack` in each environment, and the three
features the services read, `inventory.expose_region`,
`orders.forward_region`, and `pricing.regional_currency`. The features are
created off in both environments, and a re-run of `setup.sh` turns them off
again, so it leaves the stack at its baseline.

The two environments' client-side keys are written into a
`flagsmith-bootstrap` Secret in the `example-stack` namespace, under the keys
`staging` and `production`, their server-side keys under `staging-server` and
`production-server`, and the bootstrap account's API token under
`admin-token`. Flagsmith generates all five at seed time, so they cannot live
in the manifests Flux reconciles; `setup.sh` writes the Secret with
`kubectl`. Flux prunes only what it applied, so a reconcile leaves the Secret
alone, and the `app.kubernetes.io/managed-by` label on it records which script
owns it. The three services read `production-server` from it, and
`validate-stack.sh` reads the four environment keys to check the seed.

The admin token and the server-side keys are credentials, not identifiers.
The admin token acts as the bootstrap account, an organization administrator.
A server-side key reads its environment's whole document, every flag and
segment rule in it, including flags marked server-side only, which a
client-side key cannot read. Like every value in this stack they are
demo-only. Anyone who can read Secrets in the `example-stack` namespace can
read all five, and the server-side production key is also in the environment
of the `go-api`, `go-grpc`, and `rust-inventory` containers, so anyone who can
exec into those pods or read their environment can read it too.

The dashboard reads its own feature flags from a Flagsmith project too, the
vendor's hosted one by default. The seed creates a second organization and
project, both `flagsmith-dashboard`, with one environment, `dashboard`, and
no flags, since the dashboard has a built-in default for each. The
organization exists because Flagsmith's free plan, the default when
self-hosting too, allows one project per organization. Its client-side key
goes into a
`flagsmith-dashboard` Secret in the `flagsmith` namespace, under
`client-key`, which the Deployment reads as `FLAGSMITH_ON_FLAGSMITH_API_KEY`;
`setup.sh` restarts Flagsmith when the key changes, because Django reads it
only at startup.

The bootstrap login is `bootstrap@flagsmith.local` with the password
`--flagsmith-password` sets, `example-stack-demo` by default. It is a
demo-only credential like every other one in this stack. Flagsmith runs
Django's password validators on signup, so a short or common password is
rejected.

## Feature flags

Each service reads one flag from the `production` environment of the
`example-stack` project in Flagsmith.

| Flag | Service | While it is on |
|---|---|---|
| `inventory.expose_region` | `rust-inventory` | list and get items carry a `region`: `us-east` for `east`, `eu-west` for `west` |
| `orders.forward_region` | `go-api` | the pricing request carries the inventory item's region |
| `pricing.regional_currency` | `go-grpc` | a price request for `eu-west` is priced in EUR |

Each flag is inert alone, and so is every pair: `go-grpc` sees a region
only when both of the others are on, and with only its own flag on no
request names one. With all three on, an order for Gadget, the `west`
warehouse item, is priced in EUR and `go-api` answers 422, the symptom
scenario 3 produces through `REGIONAL_PRICING`, from a different cause.
Orders for Widget and Sprocket, both `east`, still succeed. With any
flag off every order is priced in USD. [Scenario 4](scenarios.md#scenario-4-feature-flag-triple)
enables the three flags in sequence and checks the stack after each change.

`go-api` and `go-grpc` use Flagsmith's server-side Go SDK,
`flagsmith-go-client`, wrapped once in `internal/flags`, in local
evaluation mode. `rust-inventory` reads the same environment document
with a client of its own, `src/flags.rs`, on a thread that copies each
flag's on/off state into a snapshot the request handlers read: the
`flagsmith` crate at 3.1.1 holds its lock across the refresh request and
panics on a document it cannot parse, and its TLS stack needs a C
toolchain in the image build, so the stack does without it. It
evaluates no segments, identities, or multivariate values, which the
stack's flags do not use. Each service fetches its environment's
document from the in-cluster API, `FLAGSMITH_API_URL`, which is
`http://flagsmith.flagsmith.svc.cluster.local:8000/api/v1/`, every ten
seconds, and evaluates flags against that copy, so a request never waits
on Flagsmith. There is no real-time channel: a change made in the
dashboard reaches a service within about ten seconds.

The key is `FLAGSMITH_SERVER_KEY`, read from the `production-server` key
of the `flagsmith-bootstrap` Secret through an optional reference.
Flagsmith serves the environment document only to a server-side key, so
a service whose key is missing, empty, or client-side makes no request
and reads every flag as off. A service reads every flag as off, too, until its first
fetch succeeds, which is the case while Flagsmith is unreachable at
startup. Once a fetch has succeeded, an unreachable Flagsmith leaves the
last document in place, so the flags keep the values they had. A flag
the document does not name is off.

`setup.sh` applies the services only after the seed has written the key,
so on a fresh cluster they start with it and need no restart.

## How the services are built

Every image is a multi-stage Dockerfile built by podman through
`scripts/build.sh`, which regenerates the proto code first. Go services
build static binaries onto `gcr.io/distroless/static-debian12`;
`rust-inventory` builds a release binary onto
`gcr.io/distroless/cc-debian12`. Every base image is pinned by tag
and digest.

Every Go Dockerfile hashes `go.mod` and `go.sum` into a sentinel inside
the module cache mount and wipes the mount when the hash changes, so a
stale cache from before a dependency change cannot poison a later
build. The failure scenarios do not build their own images: each one is
a kustomize overlay over the same four.

Images are tagged `:latest` and pushed to the local registry. Because
the tag does not change, `setup.sh` restarts the Deployments after a
reconcile so a rebuild is actually picked up.
