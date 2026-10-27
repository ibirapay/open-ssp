# Build/run box for the open-ssp regtest stack (operators, signer, LDK, SSP, bitcoind, Electrs,
# Postgres). Host main has no sudo, so the system packages live here. Repo + .regtest caches live
# in the named volume mounted at /home/lab (see run.sh); the host clone is only for editing/pushing.
FROM ubuntu:24.04

RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      build-essential pkg-config libssl-dev libzmq3-dev libprotobuf-dev protobuf-compiler \
      postgresql libpq-dev libclang-dev git curl unzip ca-certificates tmux jq \
    && rm -rf /var/lib/apt/lists/*

# Go: the operator's go.mod asks for >= 1.27.0; GOTOOLCHAIN pins the toolchain Go downloads on first
# build (1.27.2 = latest patch on 2026-10-19; plain "auto" would fetch exactly 1.27.0).
ARG GO_VERSION=1.26.8
RUN curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz" | tar -C /usr/local -xz

RUN useradd -m -s /bin/bash lab
USER lab
WORKDIR /home/lab
RUN curl -fsSL https://sh.rustup.rs | sh -s -- -y --profile minimal --default-toolchain stable

ENV PATH=/home/lab/.cargo/bin:/usr/local/go/bin:/home/lab/go/bin:/usr/lib/postgresql/16/bin:$PATH \
    GOTOOLCHAIN=go1.27.2+auto \
    PGBIN=/usr/lib/postgresql/16/bin
CMD ["sleep", "infinity"]
