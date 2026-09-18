# example-stack

This is a minimal, realistic stack for testing and development. It is a simplified
inventory and order system and supporting services that can fail in realistic ways on demand.
It runs on k3d and podman, and once it is up, nothing in this repository makes
a request outside the cluster; see Prerequisites for what that does and does
not cover.

## Contents

- Three services with a shared PostgreSQL database, `go-api` (HTTP frontend),
  `go-grpc` (gRPC pricing), and `rust-inventory` (HTTP stock), plus a basic web
  UI and a landing page with links to all the services.
- Schema and seed data are applied by Kubernetes jobs running goose migrations.
- GitOps - a Forgejo deployment holds the manifests, Flux deploys. Flux is configured
  to accept webhooks from Forgejo for immediate reconciliation.
- Monitoring: kube-prometheus-stack (Prometheus, Alertmanager, Grafana,
  kube-state-metrics, node-exporter), with per-service dashboards, recording
  rules for error rate and latency, and alerting rules.
- A local image registry that the cluster pulls from.
- Three failure scenarios that break the stack in a specific way and revert.

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

More details are available in: [docs/topology.md](docs/topology.md) for the cluster and
its setup, [docs/services.md](docs/services.md) for each service and its
endpoints, [docs/scenarios.md](docs/scenarios.md) for the failure scenarios.

## Prerequisites

Install [podman](https://podman.io/docs/installation),
[k3d](https://k3d.io/stable/#installation),
[kubectl](https://kubernetes.io/docs/tasks/tools/), and
[Go](https://go.dev/doc/install). The scripts also use `curl`, `git`, `python3`,
and `unzip`. macOS and Linux are the supported platforms; a minimal Linux
install may need one or more of those four added. `grpcurl` is optional; the
smoke test skips its gRPC checks if it is not present.

podman is the only engine currently supported. It needs no license on a
company laptop, where Docker Desktop may, and the scripts call it directly for
builds, the registry, and the network. k3d itself works over the docker
socket, so docker support is an engine variable through four scripts plus a
machine to test it on.

`helm`, `flux`, and `protoc` are not necessary: Flux is installed from a pinned
upstream manifest, the monitoring stack is a `HelmRelease` that Flux reconciles
inside the cluster, and `scripts/build.sh` downloads a pinned protoc into
`./bin/tools`, verifies its checksum, and builds the code generator plugins from
the versions pinned in `go.mod`.

k3d drives podman through the Docker API socket, and a fresh podman install
does not point k3d at it. On macOS, either run `sudo podman-mac-helper install`
once, which links `/var/run/docker.sock` to the machine's socket, or export
`DOCKER_HOST=unix://` followed by the path that
`podman machine inspect --format '{{.ConnectionInfo.PodmanSocket.Path}}'`
prints. On Linux, enable the socket with
`systemctl --user enable --now podman.socket` and export
`DOCKER_HOST=unix://$XDG_RUNTIME_DIR/podman/podman.sock`. `setup.sh` checks
this before building anything and prints these steps if k3d cannot connect.

Standing up the stack downloads from the public internet: `github.com`, `docker.io`,
`gcr.io`, `ghcr.io`, `codeberg.org`, `proxy.golang.org`, `crates.io`, and
`prometheus-community.github.io`, plus the registries the kube-prometheus-stack
chart names for its images.

After that, nothing written for this repository makes a request outside the
cluster, and the third-party defaults known to phone home are turned off in
the manifests: Grafana's usage reporting and update checks, and Forgejo's
avatar fetching. Flux still re-fetches the chart index hourly, and the other
components have not been audited. Nothing here is air-gapped; block egress at
the podman machine if you need it to be.

A podman machine with 4 CPUs and 8 GiB of memory brings the stack up in less than
ten minutes from a cold start and uses about 5 GiB of disk while it is up.
`setup.sh` requires at least 4 GiB of memory and checks for every command
above, a running podman machine, and a reachable engine socket before it
builds. [docs/topology.md](docs/topology.md) has the measured peaks.

## Running example-stack

```sh
make up        # registry, cluster, images, GitOps, monitoring, services, smoke
make smoke     # exercise the service APIs
make validate  # pods, ingress, metrics, Prometheus targets, Flux
make build     # registry, proto code, image builds and pushes
make down      # delete cluster, registry, network, kubeconfig
make lint      # shellcheck, actionlint, semgrep; needs no cluster
make test      # Go and Rust unit tests; needs no cluster
```

Each cluster target runs one script in `scripts/` with its defaults:
`setup.sh`, `smoke-test.sh`, `validate-stack.sh`, `build.sh`, and
`teardown.sh`. To pass flags, run the script itself with `bash`; every script
takes `--help` and configures itself by flag.

`setup.sh` calls `build.sh`, so a bare `bash scripts/setup.sh` on a clean
machine does everything, and it exits non-zero if the smoke test at the end
fails. The scripts are idempotent and can be safely rerun. Reset any applied
scenario before rerunning `setup.sh`, because its seed push restores the
manifests in Forgejo but not the database, so a scenario that changed the
schema stays broken until its script is run with `--reset`. `teardown.sh` keeps
the built images by default; passing `--remove-images` deletes them.

The cluster gets its own kubeconfig at `$HOME/.kube/example-stack.yaml` and
never rewrites the default one:

```sh
export KUBECONFIG=$HOME/.kube/example-stack.yaml
kubectl -n example-stack get pods
```

## Reaching example-stack

The stack uses non-default host ports so it can run beside whatever else is on
the machine. It claims three, and each one is overridable with a flag on `setup.sh`:

| Port | Purpose | setup.sh flag |
|---|---|---|
| 8090 | HTTP through the cluster's Traefik ingress | `--ingress-port` |
| 6551 | Kubernetes API | `--k8s-api-port` |
| 5111 | local image registry | `--registry-port` |

Everything is HTTP; no Ingress declares TLS, so the cluster publishes no HTTPS
port. `--ingress-port` also rewrites the links on the landing page and in the
UI.

Everything HTTP is reachable at a `*.localhost` hostname. `curl`, Chrome, and
Firefox resolve those names to 127.0.0.1 themselves, with no hosts-file
editing, which is all the scripts and the links below need. Safari and every
other tool use the system resolver, which does not resolve those names on
macOS and does so on Linux only under systemd-resolved or nss-myhostname; for
those, add one `/etc/hosts` entry per hostname below:

| URL | Purpose |
|---|---|
| http://example-stack.localhost:8090/ | Landing page, links to everything |
| http://ui.localhost:8090/ | Order-management UI |
| http://goapi.localhost:8090/ | go-api |
| http://rust.localhost:8090/ | rust-inventory |
| http://forgejo.localhost:8090/ | Forgejo |
| http://grafana.localhost:8090/ | Grafana |
| http://prometheus.localhost:8090/ | Prometheus |

`go-grpc` speaks HTTP/2 only and is not exposed through the ingress. You can reach it
with a port-forward:

```sh
kubectl -n example-stack port-forward svc/go-grpc 29090:9090
grpcurl -plaintext localhost:29090 echo.v1.EchoService/Health
```

The smoke test opens its own forward on 19090, so a manual one on that port
would collide with it.

Every credential is a demo-only default, so the stack comes up the same
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
accepted. The value is there because the services and the migration Jobs build
a connection string from it. The browser UI never holds the bearer token: nginx
injects it server-side from the Secret, through the envsubst step in
`k8s/apps/base/ui/nginx.conf.template`, so the token has one home.

`setup.sh` sets the Forgejo bootstrap password on every run. Pass
`--forgejo-password` for a different one, or change it afterwards:

```sh
kubectl -n forgejo exec deploy/forgejo -- \
  forgejo admin user change-password --username bootstrap --password '<new>'
```

## Failure scenarios

Each failure scenario pushes a kustomize overlay to Forgejo, which Flux reconciles, and
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
and a failed one exits `demo.sh` non-zero.

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
- **`--verify` on a scenario's `demo.sh`** checks that the scenario broke what it
  expects to break, and that `--reset` put the stack back correctly.

```sh
go build ./... && go vet ./... && go test ./...
(cd rust-inventory && cargo test)
```

## Building

Image builds are Dockerfile builds run by podman through `scripts/build.sh`,
which regenerates the proto code first. Generated proto code is committed;
regenerate it, don't edit it by hand.

The application images, their base images, and PostgreSQL are pinned by tag and
digest. Flux is installed from the release manifest for a pinned version, and
the monitoring stack is pinned to a chart version; the images inside those two
are whatever the release and the chart name.

## Contributing

This is an individually maintained project. Pull requests are appreciated,
review may take a while, and some will not be accepted. Every commit needs a
`Signed-off-by:` trailer, which `git commit -s` adds;
[CONTRIBUTING.md](.github/CONTRIBUTING.md) has the rest.

Install the commit hooks once:

```sh
prek install
```

They run `gofmt`, `go vet`, `cargo fmt --check`, `cargo clippy`, shellcheck
over the scripts, and actionlint over the workflows, at the versions pinned in
the Makefile; shellcheck and actionlint are downloaded into `./bin/tools`
against a checksum. semgrep is not in the hook, because it starts a container
and fetches its rules on every run. `make lint` runs it by hand, from the PATH
when that version is installed or from its pinned container when podman is
running, and the workflow always runs it. Tests are not in the hook either:
`make test` runs them, and so do the workflows.

Nothing runs directly on push currently. Both workflows are dispatched against a branch before
merge:

```sh
gh workflow run checks.yml --ref <branch>   # gofmt, go vet, go test, shellcheck, actionlint, semgrep
gh workflow run rust.yml --ref <branch>     # cargo fmt, clippy, and cargo test
```

As a result they don't appear as pull request checks. You can list results with
`gh run list --workflow=checks.yml` and `gh run list --workflow=rust.yml`.

Dependabot opens monthly pull requests for Go modules, Rust crates, the
Dockerfile base images, and the GitHub Actions. Go and Rust minor and patch
updates are grouped and majors come alone; image and action updates are
grouped whatever their size. The Rust build image is on Dependabot's ignore
list and moves by hand together with `rust-toolchain.toml`, and so do
the images and chart versions pinned in the manifests and scripts.

## License

[Apache License, Version 2.0](LICENSE).
