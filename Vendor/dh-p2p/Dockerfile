# syntax=docker/dockerfile:1

FROM rust:1-bookworm AS builder

WORKDIR /app

# Cache dependencies before copying sources
COPY Cargo.toml Cargo.lock ./
RUN mkdir src \
    && echo 'fn main() {}' > src/main.rs \
    && cargo build --release \
    && rm -rf src

COPY src ./src
RUN touch src/main.rs \
    && cargo build --release

FROM debian:bookworm-slim AS runtime

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /app/target/release/dh-p2p /usr/local/bin/dh-p2p

EXPOSE 1554/tcp

# Config via env (recommended on Dokku) or CLI flags.
#   dokku config:set instaon-relay \
#     SERIAL=YOUR_SERIAL RELAY=true CLOUD=instaon AUTH_TYPE=0 \
#     PORT_SPEC=0.0.0.0:1554:554
CMD ["dh-p2p"]
