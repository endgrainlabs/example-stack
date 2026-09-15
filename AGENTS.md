# Agent guide

This repository is the reference environment of Endgrain Labs: a small distributed system on a local k3d cluster that breaks in realistic ways on demand. Go and Rust services live in `go-api/`, `go-grpc/`, `rust-inventory/`, and `migrate/` as one Go module plus one cargo crate; `k8s/` holds the manifests (`apps/base` for the services, `infra/` for Forgejo, Flux, and monitoring); `scenarios/` holds the failure scenarios and their kustomize overlays; `scripts/` holds bring-up, teardown, build, smoke, and validation; `docs/` holds the topology, service, and scenario pages.

## Build and test

- `go build ./...`, `go vet ./...`, `go test ./...` at the repository root, `cargo fmt --check`, `cargo clippy -- -D warnings`, `cargo test` in `rust-inventory/`, and `make lint` for shellcheck, actionlint, and semgrep at the versions pinned in the Makefile (`make test` runs the Go and Rust tests). These need no permission and no cluster.
- The tests need no database and no cluster: the Go tests fake `go-api`'s backends and its database, and `cargo test` runs the `rust-inventory` handlers that answer before a query. Behavior that needs a live stack belongs in `scripts/smoke-test.sh` or in a scenario's `demo.sh --verify`.
- `bash scripts/setup.sh` brings the cluster up and `bash scripts/teardown.sh` destroys it. These, `scripts/build.sh`, and the scenario scripts need podman, k3d, and a cluster, so ask first.
- `scripts/build.sh` regenerates the proto code before building images. It needs no preinstalled protoc: it downloads a pinned one into `./bin/tools` against a checksum and builds the plugins from the `tool` directives in `go.mod`.
- Every workflow is `workflow_dispatch` only; nothing runs on push. Before merge, run `gh workflow run checks.yml --ref <branch>` and `gh workflow run rust.yml --ref <branch>`.

## Conventions

- Code comments: a line or two stating the why the code cannot show. No pull request numbers.
- Generated code is committed: regenerate, never hand-edit.
- Shell: extend existing scripts rather than adding standalone ones; scripts are invoked with `bash`, not marked executable; target bash 3.2.
- A failed or fragile command is a script defect: fix it in the script that owns the area, not in a doc.

## Latitude

- True claims and good outcomes over agreement or literal execution. If a request rests on a mistaken premise, say so before executing it.
- Fix small adjacent problems in the current pull request; deferring is the exception.
- Reading, building, unit tests, and linting need no permission. Narrate before adding a dependency, replacing a flag or image, or touching an authentication surface. Ask before destructive operations and anything that publishes outside the repository.

## Git and pull requests

- Never commit to the default branch. Branch, then pull request; the maintainer merges.
- Pull requests are squash-merged: add commits on top, never amend or force-push.
- Conventional commit subjects: `type(scope): subject`.
- AI attribution per CONTRIBUTING.md: an `Assisted-by:` trailer; author and committer are human. Never emit session links.
