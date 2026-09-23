# syntax=docker/dockerfile:1.7
FROM docker.io/library/golang:1.27.1@sha256:f44f6e88636cfb311f9ebace870ded69d943f227bb3cb27d32ffd84ea18c43ea AS build
WORKDIR /src
COPY go.mod go.sum ./
# Sentinel-based cache invalidation: hash go.mod+go.sum into a marker
# inside the /go/pkg/mod cache mount, and wipe the mount when the stored
# hash differs. Without this, a stale cache mount from before a go.mod
# change poisons the next build with "no required module provides ..."
# errors. Each Dockerfile self-heals; no build-script support needed.
RUN --mount=type=cache,id=example-stack-go-cache,target=/go/pkg/mod \
    --mount=type=cache,id=example-stack-go-build,target=/root/.cache/go-build \
    SENTINEL="$(cat go.mod go.sum | sha256sum | cut -c1-16)"; \
    if [ "$(cat /go/pkg/mod/.gomod-sentinel 2>/dev/null)" != "$SENTINEL" ]; then \
        rm -rf /go/pkg/mod/* /root/.cache/go-build/*; \
        printf '%s' "$SENTINEL" > /go/pkg/mod/.gomod-sentinel; \
    fi && \
    go mod download
COPY go-api/ ./go-api/
COPY go-grpc/proto/pricingpb/ ./go-grpc/proto/pricingpb/
COPY internal/ ./internal/
RUN --mount=type=cache,id=example-stack-go-cache,target=/go/pkg/mod \
    --mount=type=cache,id=example-stack-go-build,target=/root/.cache/go-build \
    CGO_ENABLED=0 go build -o /go-api ./go-api

FROM gcr.io/distroless/static-debian12:latest@sha256:d75cdd72874d4790092fcb1b058493ecf6bb5bf2b2b897045b00ff01d91843f2
COPY --from=build /go-api /go-api
ENTRYPOINT ["/go-api"]
