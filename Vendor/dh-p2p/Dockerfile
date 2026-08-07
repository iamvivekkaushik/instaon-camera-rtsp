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

# Local RTSP tunnel port (override with -p / --port)
EXPOSE 1554/tcp

# Bind must be 0.0.0.0 for Docker/Dokku (binary default is 127.0.0.1).
# Dokku (replaces CMD — include the binary name):
#   dokku ps:set instaon-relay dockerfile-start-cmd 'dh-p2p --relay --cloud=instaon --type=0 --port=0.0.0.0:1554:554 --serial=YOUR_SERIAL'
CMD ["dh-p2p"]
