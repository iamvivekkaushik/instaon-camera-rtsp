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
COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

# Local RTSP tunnel port (override with -p / --port)
EXPOSE 1554/tcp

ENTRYPOINT ["docker-entrypoint.sh"]
# Args come from env (Dokku config) or docker run CLI.
# Required: SERIAL
# Optional: RELAY=1 CLOUD=instaon AUTH_TYPE=0 USERNAME PASSWORD BIND=0.0.0.0:1554:554
CMD []
