# Topology

This is how the cluster is put together: the k3d cluster and its
registry, the GitOps configuration, the monitoring stack, and how the
services relate. See [services.md](services.md) for further details
about each service.

## The cluster

`scripts/setup.sh` creates a k3d cluster named `example-stack` with one
server node and one agent node, running a k3s image pinned by tag and
digest. k3d publishes the cluster's Traefik ingress on host port 8090
(HTTP) and the Kubernetes API on 6551, both bound to loopback like every
host port the stack opens. No Ingress declares TLS, so no HTTPS port is
published. The cluster writes its own kubeconfig
to `$HOME/.kube/example-stack.yaml` and leaves the default kubeconfig
untouched, so the context the shell already had is unchanged.

On a podman machine with 4 CPUs and 8 GiB of memory the stack's
containers peak just under 3 GiB of memory together when starting.
The two k3s nodes each burst past a full core while the images load,
the first run takes under ten minutes from cold start and about
seven minutes with the images already built. A re-run reconciles in
under two minutes. The cluster takes about 5 GiB of the machine's
disk while it is up and cleans that upon teardown. By default teardown
keeps the built images and the k3s image, which are under 1 GiB, plus
the Go and Rust build caches podman holds between builds. `setup.sh`
enforces a floor of 4 GiB of memory, which is the smallest machine that
leaves that peak headroom.

Flagsmith asks for 300Mi of memory and 300m of CPU and is capped at
500Mi of memory, the figures its Helm chart suggests in the
commented-out block of its values file, with no CPU limit like the
rest of the stack: under the chart's 500m its startup throttled at 78%
and fired CPUThrottlingHigh. Measured on this stack after a bring-up,
idle, with the one gunicorn worker the Deployment sets, it holds 331Mi
and about 14m of CPU: above its request, inside its limit. Its image
is the second long pull of a cold start after the k3s one.

Besides the three host ports, scripts open short-lived port-forwards on
13000 (Forgejo bootstrap), 18000 (Flagsmith bootstrap), 18080, 18081,
18082, 19090, and 19091 (smoke test and stack validation), and 19092
(the go-grpc health call in a scenario's `--verify`).

Namespaces:

| Namespace | Description |
|---|---|
| `example-stack` | the services, PostgreSQL, the migration Jobs, the landing page, dashboards, alert rules |
| `forgejo` | the in-cluster Git server |
| `flux-system` | the Flux controllers, the GitRepository, the Kustomizations, the Receiver |
| `monitoring` | kube-prometheus-stack and the HelmRelease that manages it |
| `flagsmith` | the self-hosted Flagsmith server and its migration Job |

## The registry

A `registry:2` container named `example-stack-registry` runs on host
port 5111 and is joined to the k3d network. Each node reaches it as
`example-stack-registry:5000`. Each node's containerd is configured
with a mirror entry for that name, and a `local-registry-hosting`
ConfigMap in `kube-public` advertises it.

`scripts/build.sh` starts the registry container if it is not already
up, then builds the four images (`go-api`, `go-grpc`, `rust-inventory`,
`migrate`) and pushes them as
`localhost:5111/example-stack/<service>:latest`. The manifests reference
`example-stack-registry:5000/example-stack/<service>:latest`, the same
images under the name the nodes use.

`k3d cluster stop` disconnects containers that k3d does not own, so the
bring-up reconnects the registry to the network on each run.

## GitOps

Deployment runs through Git. Forgejo holds the manifests inside the
cluster and Flux reconciles from Forgejo. When starting the cluster, `setup.sh`

1. applies the Forgejo manifests directly. This is the one
   bootstrap step outside GitOps. Something has to hold the repository.
2. creates a `bootstrap` admin user and an access token
through the Forgejo command line inside the pod, then creates the
`endgrainlabs/example-stack` organization and repository through the
Forgejo API. That token is stored in a `forgejo-bootstrap` Secret once
the services' namespace exists, and the scenario scripts reuse it
rather than minting one on every run.
3. pushes a snapshot of `k8s/apps/base`,
`k8s/infra/monitoring`, `k8s/infra/monitoring-flux`, and
`k8s/infra/flagsmith` into that repository.
4. installs Flux from the pinned upstream manifest for `v2.8.5`. The
image reflector and image automation controllers are scaled to zero:
the stack defines no image automation resources and they would idle at
real cost.
5. applies the Flux objects in `k8s/infra/flux`: a `GitRepository`
pointed at the in-cluster Forgejo, four `Kustomization` objects
(`monitoring`, `apps`, `monitoring-flux`, `flagsmith`), and a
`Receiver`.
6. creates a Forgejo webhook that calls the Receiver, so a push
reconciles immediately instead of waiting for the poll interval.
7. seeds Flagsmith through its REST API once that Kustomization
reconciles: a bootstrap account, the `example-stack` organization and
project, and the `staging` and `production` environments. The account's
API token and the two client-side environment keys go into a
`flagsmith-bootstrap` Secret in the `example-stack` namespace, under
the keys `admin-token`, `staging`, and `production`.

`forgejo-bootstrap` and `flagsmith-bootstrap` are the only two
Kubernetes objects in the `example-stack` namespace that a script
writes rather than Flux.
Both hold values minted while the stack comes up, which cannot be
written into manifests ahead of time. Flux prunes only what it applied,
so neither is removed by a reconcile, and both carry an
`app.kubernetes.io/managed-by=setup.sh` label saying so.

The `apps` and `monitoring-flux` kustomizations depend on `monitoring`,
because the Prometheus operator custom resource definitions must exist
before a `ServiceMonitor` or a `PrometheusRule` will apply. `flagsmith`
depends on `apps`: it registers a `ServiceMonitor` too, and its
migration Job needs the `flagsmith` database in the PostgreSQL that
`apps` brings up.

A failure scenario works in the same way. It clones the Forgejo
repository, commits an overlay, pushes, and patches the `apps`
Kustomization to point at the overlay path. Reverting points the path
back at `./k8s/apps/base`.

## The monitoring stack

`k8s/infra/monitoring` installs `kube-prometheus-stack` through a Flux
`HelmRelease`, pinned to chart version `82.15.1`. It provides
Prometheus, Alertmanager, Grafana, kube-state-metrics, node-exporter,
and the Prometheus operator custom resource definitions.

Retention and resource requests are scaled down for a typical laptop,
2 days and 1 GB of metrics. Prometheus selects
`ServiceMonitor`, `PodMonitor`, and `PrometheusRule` objects from every
namespace, not only chart-labeled ones.

What is collected

- Each service registers a `ServiceMonitor` in `k8s/apps/base`. `go-api`
and `rust-inventory` are scraped on their HTTP port. `go-grpc` serves
metrics on a separate HTTP port, 9091, and is scraped there.
- A `PodMonitor` in `k8s/infra/monitoring-flux` scrapes the
Flux controllers, so reconciliation itself is visible in Prometheus.
- `k8s/apps/base/prometheus-rules.yaml` records error rate and p50,
p90, and p99 latency for each service, and defines alerts for high
error rate, high latency, crash looping, readiness failures, and
replica mismatches. `scripts/validate-stack.sh` drives traffic through
all three services and fails if any of the three p99 recording rules
returns no samples, so a mistyped metric name cannot leave a rule
healthy and empty.
- Four Grafana dashboards are provisioned by ConfigMap and picked up by
the Grafana sidecar. There is one per service as well as a consolidated
view.

Helm is used here and nowhere else in this repository. Everything else
is plain YAML rendered by kustomize.

## How the services relate

```
                   +----------------+
                   |    go-api      |
                   |   frontend     |
                   |   HTTP :8080   |
                   +---+--------+---+
                       |        |
             gRPC :9090|        |HTTP :8081
                       |        |
              +--------+--+  +--+---------------+
              |  go-grpc  |  |  rust-inventory  |
              |  pricing  |  |      stock       |
              | stateless |  |                  |
              +-----------+  +--------+---------+
                       |              |
                       |     +--------+--------+
                       +-----+   PostgreSQL    |
                             |  orders db      |
                             |  inventory db   |
                             |  flagsmith db   |
                             +-----------------+
```

`go-api` is the service a client talks to. Creating an order calls
`rust-inventory` to check stock, calls `go-grpc` for a price, validates
the currency, and writes the order to its own database. All calls
between services use in-cluster Service names.

A single PostgreSQL Deployment holds all three databases.
`rust-inventory` owns `inventory`, `go-api` owns `orders`, and the
Flagsmith server in its own namespace owns `flagsmith`. No service
creates its own schema. Migration Jobs do this before the services need
it, and a service fails at startup if the schema is missing.

Data resides on a 100Mi local-path volume. It survives pod restarts and
`k3d cluster stop`, and is lost on `k3d cluster delete`, which is what
`teardown.sh` does.

## The browser surfaces

Traefik routes by hostname on port 8090, over HTTP only

- `example-stack.localhost` to the
landing page
- `ui.localhost` to the order-management UI
- `goapi.localhost` and `rust.localhost` to their services
- `forgejo.localhost`, `grafana.localhost`, `prometheus.localhost`, and
  `flagsmith.localhost` to the infrastructure

The UI is an nginx container that serves static files and proxies the
API paths to `go-api` and `rust-inventory`, injecting the demo bearer
token server-side so the browser never holds a credential. The token
reaches nginx from the Secret through the image's envsubst step.
