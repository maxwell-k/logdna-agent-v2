# syntax = docker/dockerfile:1.0-experimental
ARG BUILD_IMAGE

FROM ${BUILD_IMAGE} as build

ENV _RJEM_MALLOC_CONF="narenas:1,tcache:false,dirty_decay_ms:0,muzzy_decay_ms:0"
ENV JEMALLOC_SYS_WITH_MALLOC_CONF="narenas:1,tcache:false,dirty_decay_ms:0,muzzy_decay_ms:0"

ARG SCCACHE_BUCKET
ENV SCCACHE_BUCKET=${SCCACHE_BUCKET}

ARG SCCACHE_REGION
ENV SCCACHE_REGION=${SCCACHE_REGION}

# Create the directory for agent repo
WORKDIR /opt/logdna-agent-v2

# Only add dependency lists first for caching
COPY Cargo.lock                     .
COPY Cargo.toml                     .
COPY bin/Cargo.toml                 bin/Cargo.toml
COPY common/config-macro/Cargo.toml common/config-macro/
COPY common/config/Cargo.toml       common/config/
COPY common/fs/Cargo.toml           common/fs/
COPY common/http/Cargo.toml         common/http/
COPY common/journald/Cargo.toml     common/journald/
COPY common/k8s/Cargo.toml          common/k8s/
COPY common/metrics/Cargo.toml      common/metrics/
COPY common/middleware/Cargo.toml   common/middleware/
COPY common/source/Cargo.toml       common/source/

# Create required scaffolding for dependencies
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
RUN LIBDIRS=$(find . -name Cargo.toml -type f -mindepth 2 | sed 's/Cargo.toml//') \
    && for LIBDIR in ${LIBDIRS}; do \
        mkdir "${LIBDIR}/src" \
        && touch "${LIBDIR}/src/lib.rs"; \
    done \
    && echo "fn main() {}" > bin/src/main.rs

# Build cached dependencies
RUN --mount=type=secret,id=aws,target=/root/.aws/credentials \
    if [ -z "$SCCACHE_BUCKET" ]; then unset RUSTC_WRAPPER; fi; \
    cargo build --release && sccache --show-stats

# Delete all cached deps that are local libs
RUN grep -aL "github.com" target/release/deps/* | xargs rm \
  && rm target/release/deps/libconfig_macro*.so

# Add the actual agent source files
COPY . .

# Rebuild the agent
RUN --mount=type=secret,id=aws,target=/root/.aws/credentials \
    if [ -z "$SCCACHE_BUCKET" ]; then unset RUSTC_WRAPPER; fi; \
    cargo build --release && strip ./target/release/logdna-agent && \
    sccache --show-stats

# Use ubuntu as the final base image
FROM registry.access.redhat.com/ubi8/ubi-minimal:8.2

ARG REPO
ARG BUILD_TIMESTAMP
ARG VCS_REF
ARG VCS_URL
ARG BUILD_VERSION

LABEL org.opencontainers.image.created="${BUILD_TIMESTAMP}"
LABEL org.opencontainers.image.authors="LogDNA <support@logdna.com>"
LABEL org.opencontainers.image.url="https://logdna.com"
LABEL org.opencontainers.image.documentation=""
LABEL org.opencontainers.image.source="${VCS_URL}"
LABEL org.opencontainers.image.version="${BUILD_VERSION}"
LABEL org.opencontainers.image.revision="${VCS_REF}"
LABEL org.opencontainers.image.vendor="LogDNA Inc."
LABEL org.opencontainers.image.licenses="MIT"
LABEL org.opencontainers.image.ref.name=""
LABEL org.opencontainers.image.title="LogDNA Agent"
LABEL org.opencontainers.image.description="The blazingly fast, resource efficient log collection client"

ENV DEBIAN_FRONTEND=noninteractive
ENV _RJEM_MALLOC_CONF="narenas:1,tcache:false,dirty_decay_ms:0,muzzy_decay_ms:0"
ENV JEMALLOC_SYS_WITH_MALLOC_CONF="narenas:1,tcache:false,dirty_decay_ms:0,muzzy_decay_ms:0"

RUN microdnf update -y \
    && microdnf install ca-certificates libcap shadow-utils.x86_64 -y \
    && rm -rf /var/cache/yum

# Copy the agent binary from the build stage
COPY --from=build /opt/logdna-agent-v2/target/release/logdna-agent /work/
WORKDIR /work/
RUN chmod -R 777 .

RUN setcap "cap_dac_read_search+p" /work/logdna-agent
RUN groupadd -g 500 logdna && \
useradd -u 5000 -g logdna logdna

CMD ["./logdna-agent"]
