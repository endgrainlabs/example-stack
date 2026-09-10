# example-stack

A minimal, current stack for testing and development, whose services fail in
realistic ways on demand. It is the reference environment of Endgrain Labs: a
small distributed system on a local k3d cluster, with failure scenarios that
break it in specific ways and revert.

It sends nothing outside the cluster.

## What it contains

- Three services over a shared PostgreSQL: `go-api` (HTTP frontend),
  `go-grpc` (gRPC pricing), `rust-inventory` (HTTP stock), plus a browser UI
  and a landing page.
- Schema and seed data applied by Kubernetes Jobs running goose migrations.
- GitOps: an in-cluster Forgejo holds the manifests, Flux reconciles from it,
  and a webhook makes a push reconcile immediately.
- Monitoring: kube-prometheus-stack (Prometheus, Alertmanager, Grafana,
  kube-state-metrics, node-exporter), with per-service dashboards, recording
  rules for error rate and latency, and alerting rules.
- A local image registry that the cluster pulls from.
- Three failure scenarios that break the stack in a specific way and revert.

Longer descriptions: [docs/topology.md](docs/topology.md) for the cluster and
its wiring, [docs/services.md](docs/services.md) for each service and its
endpoints, [docs/scenarios.md](docs/scenarios.md) for the failure scenarios.

## Prerequisites

Install [podman](https://podman.io/docs/installation),
[k3d](https://k3d.io/stable/#installation),
[kubectl](https://kubernetes.io/docs/tasks/tools/), and
[Go](https://go.dev/doc/install). The scripts also use `curl`, `git`, `python3`,
and `unzip`. macOS and Linux are the supported platforms; a minimal Linux
install may need one or more of those four added.

No `helm` or `flux` command line tool is needed: Flux is installed from a pinned
upstream manifest, and the monitoring stack is a `HelmRelease` that Flux
reconciles inside the cluster. No `protoc` either: `scripts/build.sh` downloads
a pinned protoc into `./bin/tools`, verifies its checksum, and builds the two
code generator plugins from the versions pinned in `go.mod`.

`grpcurl` is optional; the smoke test skips its gRPC checks without it. Install
it from [fullstorydev/grpcurl](https://github.com/fullstorydev/grpcurl).

The bring-up downloads from the public internet: `github.com` for the Flux
release manifest and the pinned protoc archive, `docker.io` for k3s,
PostgreSQL, nginx, the registry, and the Go and Rust build images, `gcr.io` for
the distroless runtime images, `proxy.golang.org` for Go modules, `crates.io`
for Rust crates, `codeberg.org` for Forgejo, `ghcr.io` for the Flux controller
images, and `prometheus-community.github.io` for the kube-prometheus-stack
chart, whose own images come from the registries the chart names. Nothing
leaves the cluster after that.

The bring-up needs a podman machine with at least 4 GiB of memory; with 4 CPUs
the first run finishes in under ten minutes and a re-run in under two. `setup.sh`
checks for every command above, and for a running machine of that size, before
it builds anything, and names what is missing. The first run takes several
minutes because the kube-prometheus-stack images are large.

## Bring-up and teardown

```sh
bash scripts/setup.sh            # registry, cluster, images, GitOps, monitoring, services, smoke
bash scripts/smoke-test.sh       # exercise the service APIs
bash scripts/validate-stack.sh   # pods, ingress, metrics, Prometheus targets, Flux
bash scripts/build.sh            # registry, proto code, image builds and pushes
bash scripts/teardown.sh         # delete cluster, registry, network, kubeconfig
```

Scripts are run with `bash`, never marked executable. Every script takes
`--help` and configures itself by flag. `setup.sh` calls `build.sh`, so a bare
`bash scripts/setup.sh` on a clean machine does everything. Every phase checks
for the state it would create, so a second run against a live cluster
reconciles instead of starting over. `teardown.sh` keeps the built images by
default; pass `--remove-images` to delete them too. `setup.sh` exits non-zero
if the smoke test at the end of it fails.

The cluster gets its own kubeconfig at `$HOME/.kube/example-stack.yaml` and
never rewrites the default one:

```sh
export KUBECONFIG=$HOME/.kube/example-stack.yaml
kubectl -n example-stack get pods
```

## Ports

The stack uses non-default host ports so it can run beside whatever else is on
the machine. It claims three, and each one is a flag on `setup.sh`:

| Port | What | Flag |
|---|---|---|
| 8090 | HTTP through the cluster's Traefik ingress | `--ingress-port` |
| 6551 | Kubernetes API | `--k8s-api-port` |
| 5111 | local image registry | `--registry-port` |

Everything here is HTTP. No Ingress declares TLS, so the cluster publishes no
HTTPS port on the host.

`--ingress-port` also rewrites the links on the landing page and in the UI, so
they keep pointing at the port the stack is actually on.

Scripts also open short-lived port-forwards on 13000 (Forgejo bootstrap),
18080, 18081, 18082, 19090, and 19091 (smoke test and stack validation), and
19092 (the go-grpc health call in a scenario's `--verify`).

Everything HTTP is reachable at a `*.localhost` hostname. `curl` and every
major browser resolve those names to 127.0.0.1 with no hosts-file editing,
which is all the scripts and the links below need. The system resolver does not
on macOS, and does on Linux only under systemd-resolved or nss-myhostname; for
any other tool on macOS, or on a Linux host with neither, add one `/etc/hosts`
entry per hostname below:

| URL | What |
|---|---|
| http://example-stack.localhost:8090/ | Landing page, links to everything |
| http://ui.localhost:8090/ | Order-management UI |
| http://goapi.localhost:8090/ | go-api |
| http://rust.localhost:8090/ | rust-inventory |
| http://forgejo.localhost:8090/ | Forgejo |
| http://grafana.localhost:8090/ | Grafana |
| http://prometheus.localhost:8090/ | Prometheus |

`go-grpc` speaks HTTP/2 only and is not exposed through the ingress. Reach it
with a port-forward:

```sh
kubectl -n example-stack port-forward svc/go-grpc 19090:9090
grpcurl -plaintext localhost:19090 echo.v1.EchoService/Health
```

## Credentials

Every credential below is a demo-only default, fixed so the stack comes up the
same way on any machine. None of it is a production secret.

| System | Credential | Where it is set |
|---|---|---|
| Service APIs (`go-api`, `rust-inventory`, `go-grpc`) | bearer token `dev-token` | `k8s/apps/base/secrets.yaml` |
| PostgreSQL | user `postgres`, password `postgres` | `k8s/apps/base/secrets.yaml` |
| Forgejo | user `bootstrap`, password `password` | `--forgejo-password` on `scripts/setup.sh` |
| Grafana | `admin` / `admin` | `k8s/infra/monitoring/helmrelease.yaml` |
| Flux Receiver webhook | shared secret `example-stack-webhook-secret` | `k8s/infra/flux/receiver.yaml` |

The PostgreSQL container runs with `POSTGRES_HOST_AUTH_METHOD=trust`, so the
password is never checked and any connection from inside the cluster is
accepted. The value is there because the services and the migration Jobs build
a connection string from it.

The browser UI never holds the bearer token: nginx injects it server-side. The
configuration is `k8s/apps/base/ui/nginx.conf.template`, and the image's
envsubst step fills `${API_TOKEN}` in from the Secret at container start, so
the token has one home.

`setup.sh` sets the Forgejo bootstrap password on every run. Pass
`--forgejo-password` for a different one, or change it afterwards:

```sh
kubectl -n forgejo exec deploy/forgejo -- \
  forgejo admin user change-password --username bootstrap --password '<new>'
```

## Failure scenarios

Each scenario pushes a kustomize overlay to Forgejo, which Flux reconciles, and
each reverts with `--reset`.

| Scenario | What breaks |
|---|---|
| 1: broken service port | The `go-grpc` Service targets the wrong port. The pod stays healthy, the traffic is dropped, `go-api` order creation returns 502. |
| 2: bad migration | A migration renames a column. The Job succeeds, and `rust-inventory` queries start returning 500. |
| 3: pricing assumption | `go-grpc` returns a different currency for one warehouse. Both services are healthy, and orders for that warehouse fail with 422. |

```sh
bash scenarios/scenario-1-broken-service/demo.sh
bash scenarios/scenario-1-broken-service/demo.sh --reset
```

`--verify` asserts the result: with an apply, the symptoms the scenario page
documents; with `--reset`, the baseline. Each assertion prints PASS or FAIL,
and a failed one exits the driver non-zero.

```sh
bash scenarios/scenario-1-broken-service/demo.sh --verify
bash scenarios/scenario-1-broken-service/demo.sh --reset --verify
```

Details, expected symptoms, and what a good observer sees are in
[docs/scenarios.md](docs/scenarios.md).

## Smoke and validation

Checking happens in three layers:

- `go test ./...` and `cargo test` check the services off-cluster: `go-api`
  with its backends and database faked, `rust-inventory` on the handlers that
  answer before any query.
- `scripts/smoke-test.sh` and `scripts/validate-stack.sh` check a healthy
  stack.
- `--verify` on a scenario driver checks that the scenario broke what it says
  it breaks, and that `--reset` put the stack back.

`scripts/smoke-test.sh` checks service behavior: migration Jobs succeeded or
already garbage-collected, health and readiness, authentication rejection, the
seeded inventory, order creation across the full call graph, insufficient
stock, an unknown item, and the UI proxy paths.

`scripts/validate-stack.sh` checks the infrastructure: pod health, ingress
resolution, `/metrics` endpoints, Prometheus scrape targets, alert rules
loaded, alerts not firing, and Flux reconciliation status. It does not run the
scenarios.

Both exit non-zero on failure.

## Layout

```
go-api/          Go HTTP frontend service
go-grpc/         Go gRPC pricing and echo service, and its protos
rust-inventory/  Rust HTTP inventory service
migrate/         goose migration runner and the migration SQL
k8s/apps/base/   the services, their Ingresses, dashboards, and alert rules
k8s/infra/       Forgejo, Flux, and the monitoring stack
scenarios/       the failure scenarios and their overlays
scripts/         bring-up, teardown, build, smoke, validation
docs/            topology, services, scenarios
```

## Build and test

```sh
go build ./...
go vet ./...
go test ./...
(cd rust-inventory && cargo test)
```

The Go tests run the `go-api` handlers with an `httptest` server standing in
for `rust-inventory`, a fake of the generated client standing in for `go-grpc`,
and a `database/sql` connector standing in for PostgreSQL: authentication,
insufficient stock, an unsupported currency, an unreachable backend, a created
order and the list, and the route labels on the request counter. They also
cover the `go-grpc` service contract, including the `REGIONAL_PRICING` rules,
and the order in which `migrate` applies its embedded set and an `-extra-dir`.
The Rust tests run the `rust-inventory` handlers that answer before a query:
authentication, request validation, and liveness.

None of them need a database or a cluster. Behavior that does is covered by
`scripts/smoke-test.sh` and by `--verify` on the scenario drivers.

Image builds are Dockerfile builds run by podman through `scripts/build.sh`,
which also regenerates the proto code before building. Generated proto code is
committed; regenerate it, never edit it by hand.

The application images, their base images, and PostgreSQL are pinned by tag and
digest. Flux is installed from the release manifest for a pinned version, and
the monitoring stack is pinned to a chart version; the images inside those two
are whatever the release and the chart name.

## Contributing

Install the commit hooks once:

```sh
prek install
```

They run `gofmt`, `go vet`, `cargo fmt --check`, and `cargo clippy`. Tests are
not in the hook; the workflows run them.

Nothing runs on push. Both workflows are dispatched against a branch before
merge:

```sh
gh workflow run checks.yml --ref <branch>   # gofmt, go vet, go test
gh workflow run rust.yml --ref <branch>     # cargo fmt, clippy, and cargo test
```

The results do not appear as pull request checks. Read them with
`gh run list --workflow=checks.yml` and `gh run list --workflow=rust.yml`.
