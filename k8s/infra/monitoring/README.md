# Monitoring stack

This directory installs `kube-prometheus-stack` through a Flux `HelmRelease` into the `monitoring` namespace. It provides Prometheus, Alertmanager, Grafana, kube-state-metrics, node-exporter, and the Prometheus operator custom resource definitions (`ServiceMonitor`, `PodMonitor`, `PrometheusRule`) that the services in `k8s/apps/base` use to register themselves for scraping.

## Scope

Flux's helm-controller is used here and nowhere else in this repository. Everything else is plain YAML that kustomize renders. The chart is a large upstream system that would be expensive to re-derive by hand, and the point of this stack is to produce real signals quickly. Helm manages nothing outside this single `HelmRelease`.

## Chart version

The `HelmRelease` pins chart version `82.15.1`. Version bumps land as deliberate commits, not floating ranges. Releases are listed at https://github.com/prometheus-community/helm-charts/releases.

## Values

A minimal values set is embedded in `helmrelease.yaml`:

- Retention is reduced to 2 days and 1 GB to keep the on-disk footprint small on a laptop.
- Resource requests and limits are scaled down for laptop use. They are not production sizing.
- `serviceMonitorSelectorNilUsesHelmValues: false` and its siblings make Prometheus pick up ServiceMonitors from any namespace, not only ones the chart labels.
- The Grafana administrator password is `admin`. Demo-only, for a local cluster.
- `fullnameOverride: kps` keeps generated resource names short.
