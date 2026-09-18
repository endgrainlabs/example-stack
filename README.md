# example-stack

`example-stack` is a minimal, realistic stack for testing and development that
runs on k3d and podman. It contains a simplified inventory and order system
and supporting platform services that can fail in realistic ways on demand. It
is self-contained after startup (see [Prerequisites](#prerequisites) and
[docs/topology.md](./docs/topology.md) for details).

## Contents

`example-stack` consists of

- Three services and a shared PostgreSQL database
  - `go-api` (HTTP frontend)
  - `go-grpc` (gRPC pricing)
  - `rust-inventory` (HTTP stock)
- A basic web UI and a landing page with links to all the services
- Kubernetes Jobs that run goose migrations for the schema and seed data
- GitOps stack
  - Forgejo for local source control; it holds the service manifests
  - Flux for deployment, configured to use Forgejo as a Git source
  - Flux is pre-configured to accept webhooks from Forgejo
- Monitoring is the kube-prometheus-stack
  - Prometheus
  - Alertmanager
  - Grafana
  - kube-state-metrics
  - node-exporter
  - Pre-configured with per-service dashboards, recording rules for error rate
    and latency, and alerting rules.
- A local image registry that the cluster pulls from.
- Three failure scenarios that break the stack in a specific way and revert.

This is how they are organized in the repository

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

More details are available in: [docs/topology.md](docs/topology.md) for
the cluster and its setup, [docs/services.md](docs/services.md) for
each service and its endpoints, [docs/scenarios.md](docs/scenarios.md)
for the failure scenarios.

## Prerequisites

Running `example-stack` requires
- [podman](https://podman.io/docs/installation)
- [k3d](https://k3d.io/stable/#installation)
- [kubectl](https://kubernetes.io/docs/tasks/tools/)
- [Go](https://go.dev/doc/install)

Running the make targets and scripts requires
- `curl`
- `git`
- `python3`,
- `unzip`

`example-stack` currently supports macOS and Linux. A minimal Linux
install may need one or more script requirements to be installed.
The scripts also may run `grpcurl`, but the smoke test skips the gRPC checks
if it is not present.

The only container engine currently supported is podman. Podman
doesn't require a licence for commercial use, and the scripts call
it directly for builds, the registry, and the network. k3d itself uses
the docker socket, so docker support is an engine variable in
four scripts.

`helm`, `flux`, and `protoc` are **not** required: Flux is installed from a
pinned upstream manifest, the monitoring stack is a `HelmRelease` that Flux
reconciles within the cluster, and `scripts/build.sh` downloads a pinned
protoc binary from the project's release into `./bin/tools` relative to the
repository root, verifies its checksum, and builds the code generator plugins
from the versions pinned in `go.mod`.

k3d drives podman through the Docker API socket, and a fresh podman install
won't point k3d at it. On macOS, either run `sudo podman-mac-helper install`
once, which links `/var/run/docker.sock` to the machine's socket, or export
`DOCKER_HOST=unix://` followed by the path that `podman machine inspect
--format '{{.ConnectionInfo.PodmanSocket.Path}}'` prints. On Linux, enable the
socket by running `systemctl --user enable --now podman.socket` and export
`DOCKER_HOST=unix://$XDG_RUNTIME_DIR/podman/podman.sock`. `setup.sh` checks
this before building anything and prints these steps if k3d cannot connect.

Starting up the stack downloads from
- `github.com`
- `docker.io`
- `gcr.io`
- `ghcr.io`
- `codeberg.org`
- `proxy.golang.org`
- `crates.io`
- `prometheus-community.github.io`
- the registries the kube-prometheus-stack chart names for its images.

After startup, nothing written for this repository makes a request outside the
cluster, and the third-party telemetry defaults that do so are turned off in
the manifests
- Grafana usage reporting and update checks
- Forgejo avatar fetching

Flux still re-fetches the chart index hourly, and the other components have
not been audited. This project is not air-gapped; block egress at the podman
machine if you need it.

The stack has been tested to start up on a podman machine with 4 CPUs and
8 GiB of memory in less than ten minutes from a cold start
and uses about 5 GiB of disk while it is up. `setup.sh` requires at least 4 GiB
of memory and checks for every command above, a running podman machine, and
a reachable engine socket before it builds. [docs/topology.md](docs/topology.md)
has more details.

## Running example-stack

The project is intended to be run with make targets that call bash scripts.

```sh
make up        # registry, cluster, images, GitOps, monitoring, services, smoke
make smoke     # exercise the service APIs
make validate  # pods, ingress, metrics, Prometheus targets, Flux
make build     # registry, proto code, image builds and pushes
make down      # delete cluster, registry, network, kubeconfig
make lint      # shellcheck, actionlint, kustomize build, semgrep; needs no cluster
make test      # Go, Rust, and Python unit tests; needs no cluster
```

Each cluster target runs one script in `scripts/` with its defaults -
`setup.sh`, `smoke-test.sh`, `validate-stack.sh`, `build.sh`, and
`teardown.sh`. To override the defaults, run scripts directly via `bash` - the
scripts take `--help` and document their supported flags.

`setup.sh` calls `build.sh`, so `make up` or a bare `bash scripts/setup.sh` on
a clean machine runs everything, and it exits non-zero if the smoke test at
the end fails. The scripts are idempotent and can be safely rerun. Reset any
applied failure scenario before rerunning `setup.sh`, because its seed push
restores the manifests in Forgejo but not the database - so a scenario that
changed the schema stays broken until its script is run with `--reset`.
`teardown.sh` keeps the built images by default; running it with the
`--remove-images` flag deletes them.

The cluster writes its own kubeconfig to `$HOME/.kube/example-stack.yaml` and
never rewrites the default one.

```sh
export KUBECONFIG=$HOME/.kube/example-stack.yaml
kubectl -n example-stack get pods
```

## Reaching example-stack

`example-stack` uses non-default host ports to avoid conflicting with anything
else running on the same machine. It claims three ports, each overridable
with a flag on `setup.sh`:

| Port | Purpose | setup.sh flag |
|---|---|---|
| 8090 | HTTP through the cluster's Traefik ingress | `--ingress-port` |
| 6551 | Kubernetes API | `--k8s-api-port` |
| 5111 | local image registry | `--registry-port` |

Everything is currently HTTP. No Ingress declares TLS, so the cluster publishes
no HTTPS port. `--ingress-port` also rewrites the links on the landing page and
in the UI.

Everything HTTP is reachable at a `*.localhost` hostname. `curl`, Chrome, and
Firefox will resolve those names to 127.0.0.1 themselves, which is all the
scripts and the links below need. Safari and other tools use the system
resolver, which does not resolve those names on macOS and does so on Linux
only under systemd-resolved or nss-myhostname. If you need those, add one
`/etc/hosts` entry per hostname below:

| URL | Purpose |
|---|---|
| http://example-stack.localhost:8090/ | Landing page, links to everything |
| http://ui.localhost:8090/ | Order-management UI |
| http://goapi.localhost:8090/ | go-api |
| http://rust.localhost:8090/ | rust-inventory |
| http://forgejo.localhost:8090/ | Forgejo |
| http://grafana.localhost:8090/ | Grafana |
| http://prometheus.localhost:8090/ | Prometheus |

`go-grpc` only speaks HTTP/2 and is not exposed through the ingress. You can
reach it with a port-forward

```sh
kubectl -n example-stack port-forward svc/go-grpc 29090:9090
grpcurl -plaintext localhost:29090 echo.v1.EchoService/Health
```

The smoke test script opens its own forward on 19090, so a manual one on
that port would collide with it.

**Every credential is a demo-only default**, so the stack comes up the same
way on any machine. None of it is a production secret.

| System | Credential | Where it is set |
|---|---|---|
| Service APIs (`go-api`, `rust-inventory`, `go-grpc`) | bearer token `dev-token` | `k8s/apps/base/secrets.yaml` |
| PostgreSQL | user `postgres`, password `postgres` | `k8s/apps/base/secrets.yaml` |
| Forgejo | user `bootstrap`, password `password` | `--forgejo-password` on `scripts/setup.sh` |
| Grafana | `admin` / `admin` | `k8s/infra/monitoring/helmrelease.yaml` |
| Flux Receiver webhook | shared secret `example-stack-webhook-secret` | `k8s/infra/flux/receiver.yaml` |

The PostgreSQL container runs with `POSTGRES_HOST_AUTH_METHOD=trust`, so the
password is never checked and any connection from inside the cluster is
accepted (the value is there because the services and the migration Jobs build
a connection string from it). The browser UI never holds the bearer token: nginx
injects it server-side from the Secret, through the envsubst step in
`k8s/apps/base/ui/nginx.conf.template`, so the token has one home.

`setup.sh` sets the Forgejo bootstrap password on every run. Pass
`--forgejo-password` to override the default or change it afterwards

```sh
kubectl -n forgejo exec deploy/forgejo -- \
  forgejo admin user change-password --username bootstrap --password '<new>'
```

## Failure scenarios

Each failure scenario pushes a kustomize overlay to Forgejo, which Flux
then reconciles. Each scenario is reverted by running its associated script
with `--reset`.

| Scenario | Description |
|---|---|
| broken service port (1) | The `go-grpc` Service targets the wrong port. The pod stays healthy, the traffic is dropped, `go-api` order creation returns 502. |
| bad migration (2) | A migration renames a column. The Job succeeds, and `rust-inventory` queries start returning 500. |
| invalid pricing assumption (3) | `go-grpc` returns a different currency for one warehouse. Both services are healthy, and orders for that warehouse fail with 422. |

To run scenario 1 and revert to the baseline state, you'd execute
```sh
bash scenarios/scenario-1-broken-service/demo.sh
bash scenarios/scenario-1-broken-service/demo.sh --reset
```

Running the scenario script with the `--verify` flag asserts the scenario's
breakage when applying the change. Running it with `--reset --verify`
asserts that the baseline is restored. Each assertion prints
PASS or FAIL, and a failed one exits `demo.sh` non-zero.

```sh
bash scenarios/scenario-1-broken-service/demo.sh --verify
bash scenarios/scenario-1-broken-service/demo.sh --reset --verify
```

Details and expected symptoms are in [docs/scenarios.md](docs/scenarios.md).

## Testing

There are four layers of testing. All exit non-zero on failure.

- **Unit tests** need no database or cluster. The Go tests run the `go-api`
  handlers with an `httptest` server standing in for `rust-inventory`, a fake
  of the generated client standing in for `go-grpc`, and a `database/sql`
  connector standing in for PostgreSQL: authentication, insufficient stock, an
  unsupported currency, an unreachable backend, a created order and the list,
  and the route labels on the request counter. They also cover the `go-grpc`
  service contract, including the `REGIONAL_PRICING` rules, and the order in
  which `migrate` applies its embedded set and an `-extra-dir`. The Rust tests
  run the `rust-inventory` handlers that answer before a query: authentication,
  request validation, and liveness.
- **`scripts/smoke-test.sh`** checks service behavior on a live stack:
  migration Jobs succeeded or already garbage-collected, health and readiness,
  authentication rejection, the seeded inventory, order creation across the
  full call graph, insufficient stock, an unknown item, and the UI proxy paths.
- **`scripts/validate-stack.sh`** checks the infrastructure: pod health,
  ingress resolution, `/metrics` endpoints, Prometheus scrape targets, alert
  rules loaded, alerts not firing, and Flux reconciliation status. It does not
  run the scenarios.
- **`--verify` on a scenario's `demo.sh`** checks that the scenario broke what
  it expects to break, and that `--reset` put the stack back correctly.

To run the tests execute `make test` or

```sh
go build ./... && go vet ./... && go test ./...
(cd rust-inventory && cargo test)
```

## Building

Image builds are Dockerfile builds run by podman through `scripts/build.sh`,
which regenerates the proto code first. Generated proto code is committed.
You should regenerate it, don't edit it by hand.

The application images, their base images, and PostgreSQL are pinned by tag
and digest. Flux is installed from the release manifest for a pinned version.
The monitoring stack is pinned to a chart version. The images in Flux and the
monitoring stack are whatever the release and the chart specify.

## Contributing

Pull requests are appreciated, but reviews may take a while and some
contributions will not be accepted. Every commit requires a
`Signed-off-by:` trailer, which `git commit -s` will add for you. See
[CONTRIBUTING.md](.github/CONTRIBUTING.md) for details.

When developing locally, install the commit hooks once with

```sh
prek install
```

The precommit hooks will run
-  `gofmt`, `go vet`, `cargo fmt --check`, and `cargo clippy`
- `shellcheck` on the scripts
- `actionlint` on the workflows
- `kustomize` build of manifest directories and scenario overlays

at the versions pinned in the Makefile. `shellcheck`, `actionlint`, and
`kustomize` are downloaded into `./bin/tools` and the binary checksums are
validated. `semgrep` runs premerge in GitHub workflows but is not in the
precommit hook, because it starts a container and fetches its rules on every
run. `make lint` runs `semgrep` manually, from the PATH when the pinned
version is installed or from its pinned container when podman is running, and
the workflow always runs it. Tests are not in the hook, either, but `make
test` runs them, and they also run premerge in GitHub workflows.

The GitHub workflows run on pull requests and on pushes to `main`, and
appear as checks on the pull request. `checks.yml` runs gofmt, go vet, go
test with the race detector, the Python tests, shellcheck, actionlint, the
kustomize build, and semgrep. `rust.yml` runs cargo fmt, clippy, and cargo
test. Both support manual workflow dispatch.

Dependabot opens monthly pull requests for Go modules, Rust crates, the
Dockerfile base images, and the GitHub Actions. Go and Rust minor and patch
updates are grouped and majors come alone. Image and action updates are
grouped whatever their size. The Rust build image is on Dependabot's ignore
list and is updated by hand with `rust-toolchain.toml`. The images and chart
versions pinned in the manifests and scripts have no Dependabot ecosystem and
are updated by hand too.

## License

[Apache License, Version 2.0](LICENSE).
