# Topology

How the cluster is put together: the k3d cluster and its registry, the GitOps
loop, the monitoring stack, and how the services relate. Read
[services.md](services.md) for what each service does.

## The cluster

`scripts/setup.sh` creates a k3d cluster named `example-stack` with one server
node and one agent node, running a k3s image pinned by tag and digest. k3d
publishes the cluster's Traefik ingress on host port 8090 (HTTP) and the
Kubernetes API on 6551. No Ingress declares TLS, so no HTTPS port is
published. The cluster writes its own kubeconfig
to `$HOME/.kube/example-stack.yaml` and leaves the default kubeconfig
untouched, so the context the shell already had is unchanged.

Namespaces:

| Namespace | Holds |
|---|---|
| `example-stack` | the services, PostgreSQL, the migration Jobs, the landing page, dashboards, alert rules |
| `forgejo` | the in-cluster Git server |
| `flux-system` | the Flux controllers, the GitRepository, the Kustomizations, the Receiver |
| `monitoring` | kube-prometheus-stack and the HelmRelease that manages it |

## The registry

A `registry:2` container named `example-stack-registry` runs on host port 5111
and is joined to the k3d network, where nodes reach it as
`example-stack-registry:5000`. Each node's containerd is configured with a
mirror entry for that name, and a `local-registry-hosting` ConfigMap in
`kube-public` advertises it.

`scripts/build.sh` starts that container if it is not already up, then builds
the four images (`go-api`, `go-grpc`, `rust-inventory`, `migrate`) and pushes
them as
`localhost:5111/example-stack/<service>:latest`. The manifests reference
`example-stack-registry:5000/example-stack/<service>:latest`, the same images
under the name the nodes use.

`k3d cluster stop` disconnects containers that k3d does not own, so the
bring-up reconnects the registry to the network on every run.

## The GitOps loop

Deployment runs through Git. Forgejo holds the manifests inside the cluster and
Flux reconciles from it.

1. `setup.sh` applies the Forgejo manifests directly. This is the one
   bootstrap step outside GitOps: something has to hold the repository.
2. It creates a `bootstrap` admin user and an access token through the Forgejo
   command line inside the pod, then creates the `endgrainlabs/example-stack`
   organization and repository through the Forgejo API.
3. It pushes a snapshot of `k8s/apps/base`, `k8s/infra/monitoring`, and
   `k8s/infra/monitoring-flux` into that repository.
4. It installs Flux from the pinned upstream manifest for `v2.8.5`. The image
   reflector and image automation controllers are scaled to zero: the stack
   defines no image automation resources and they would idle at real cost.
5. It applies the Flux objects in `k8s/infra/flux`: a `GitRepository` pointed
   at the in-cluster Forgejo, three `Kustomization` objects (`monitoring`,
   `apps`, `monitoring-flux`), and a `Receiver`.
6. It creates a Forgejo webhook that calls the Receiver, so a push reconciles
   immediately instead of waiting for the poll interval.

`apps` and `monitoring-flux` depend on `monitoring`, because the Prometheus
operator custom resource definitions must exist before a `ServiceMonitor` or a
`PrometheusRule` will apply.

A failure scenario works through this same loop: it clones the Forgejo
repository, commits an overlay, pushes, and patches the `apps` Kustomization to
point at the overlay path. Reverting points the path back at `./k8s/apps/base`.

## The monitoring stack

`k8s/infra/monitoring` installs kube-prometheus-stack through a Flux
`HelmRelease`, pinned to chart version `82.15.1`. It provides Prometheus,
Alertmanager, Grafana, kube-state-metrics, node-exporter, and the Prometheus
operator custom resource definitions.

Retention and resource requests are scaled down for a laptop: 2 days and 1 GB
of metrics. Prometheus selects `ServiceMonitor`, `PodMonitor`, and
`PrometheusRule` objects from every namespace, not only chart-labeled ones.

What is collected:

- Each service registers a `ServiceMonitor` in `k8s/apps/base`. `go-api` and
  `rust-inventory` are scraped on their HTTP port; `go-grpc` serves metrics on
  a separate HTTP port, 9091, and is scraped there.
- A `PodMonitor` in `k8s/infra/monitoring-flux` scrapes the Flux controllers,
  so reconciliation itself is visible in Prometheus.
- `k8s/apps/base/prometheus-rules.yaml` records error rate and p50, p90, and
  p99 latency for each service, and defines alerts for high error rate, high
  latency, crash looping, readiness failures, and replica mismatches.
  `scripts/validate-stack.sh` drives traffic through all three services and
  fails if any of the three p99 recording rules returns no samples, so a
  mistyped metric name cannot leave a rule healthy and empty.
- Four Grafana dashboards are provisioned by ConfigMap and picked up by the
  Grafana sidecar: one per service and a consolidated view.

Helm is used here and nowhere else in this repository. Everything else is plain
YAML rendered by kustomize.

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
                             +-----------------+
```

`go-api` is the service a client talks to. Creating an order calls
`rust-inventory` to check stock, calls `go-grpc` for a price, validates the
currency, and writes the order to its own database. All calls between services
use in-cluster Service names.

One PostgreSQL Deployment holds both databases. `rust-inventory` owns
`inventory`, `go-api` owns `orders`. Neither service creates its own schema:
migration Jobs do that before the services need it, and a service fails at
startup if the schema is missing.

Data lives on a 100Mi local-path volume. It survives pod restarts and
`k3d cluster stop`, and is lost on `k3d cluster delete`, which is what
`teardown.sh` does.

## The browser surfaces

Traefik routes by hostname on port 8090, over HTTP only: `example-stack.localhost` to the
landing page, `ui.localhost` to the order-management UI, `goapi.localhost` and
`rust.localhost` to their services, and `forgejo.localhost`,
`grafana.localhost`, and `prometheus.localhost` to the infrastructure.

The UI is an nginx container serving static files and proxying the API paths to
`go-api` and `rust-inventory`, injecting the demo bearer token server-side so
the browser never holds a credential. The token reaches nginx from the Secret
through the image's envsubst step.
