# syntax=docker/dockerfile:1.7
FROM docker.io/library/rust:1.94.1@sha256:652612f07bfbbdfa3af34761c1e435094c00dde4a98036132fca28c7bb2b165c AS build
WORKDIR /src
COPY rust-inventory/ ./
RUN --mount=type=cache,target=/usr/local/cargo/registry \
    --mount=type=cache,target=/usr/local/cargo/git \
    --mount=type=cache,target=/src/target \
    cargo build --release && \
    cp target/release/rust-inventory /rust-inventory

FROM gcr.io/distroless/cc-debian12:latest@sha256:e5d81ddde149641e2a9ba55be4545bc125c67de07508b03ba4c22e6eb0ded5aa
COPY --from=build /rust-inventory /rust-inventory
ENTRYPOINT ["/rust-inventory"]
