# Multi-stage: static-ish release binary, then a minimal non-root runtime image.
FROM rust:1.94-bookworm AS build
WORKDIR /build
COPY Cargo.toml Cargo.lock ./
COPY src ./src
RUN cargo build --release

FROM debian:bookworm-slim AS runtime
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates wget \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --system --uid 10001 --shell /usr/sbin/nologin gateway
COPY --from=build /build/target/release/sandbox-gateway /usr/local/bin/sandbox-gateway
USER gateway
EXPOSE 8090
CMD ["/usr/local/bin/sandbox-gateway"]
