# syntax=docker/dockerfile:1
# =============================================================================
# Typesense (cmigazzi fork, v31) — build & packaging pipeline.
#
# Stages:
#   toolchain : reusable builder image (ubuntu 22.04 + GCC 10 + bazelisk + lld).
#               Build it alone:  docker build --target toolchain -t typesense-builder .
#   builder   : copies the repo, bazel-builds //:typesense-server (deps fetched
#               over HTTPS with a fresh jammy CA bundle).
#   test      : builder + C++ test suite (//:typesense-test) incl. the
#               tyrec-1 model fixture, mirroring .github/workflows/tests.yml.
#   runtime-base : shared production content (base image, ca-certificates + curl,
#               EXPOSE/STOPSIGNAL/HEALTHCHECK/ENTRYPOINT). Runs as root by
#               default, matching upstream typesense/typesense.
#   runtime   : production image, drop-in for docker/deployment.Dockerfile
#               (+ HEALTHCHECK). Binary from the builder
#               stage — the hermetic release path.
#   runtime-prebuilt : same image, binary taken from the build context
#               (docker/tsbuild.sh dist-fast). Differs from `runtime` ONLY in
#               the binary COPY line.
#
# Toolchain rationale: GCC 10.5 / ubuntu:22.04 reproduces CI
# (.github/workflows/tests.yml installs g++-10 + lld on ubuntu-22.04), so all
# five GCC 13/14/15 incompatibilities are absent and the `build:modern-gcc`
# .bazelrc config is simply not needed here.
#
# Bazel version is NOT pinned in this file on purpose: bazelisk reads the
# repo's .bazelversion (=6.2.0).
# =============================================================================

ARG UBUNTU_VERSION=22.04
ARG BAZELISK_VERSION=v1.19.0

# -----------------------------------------------------------------------------
FROM ubuntu:${UBUNTU_VERSION} AS toolchain

ARG TARGETARCH
ARG BAZELISK_VERSION
ENV DEBIAN_FRONTEND=noninteractive

# Fresh CA bundle (jammy-updates 2025 roots) + toolchain.
#  - ca-certificates : GitHub/TLS fetches of the ~40 deps need current roots.
#  - lld             : REQUIRED — BUILD:106/208 pass -fuse-ld=lld.
#  - gcc-10/g++-10   : CI-parity compiler, avoids all GCC>=13 breakage classes.
#  - perl            : Ubuntu perl ships core modules (FindBin.pm) unlike Fedora.
#  - bzip2/xz-utils  : elfutils tarball is .tar.bz2; some archives are .tar.xz.
#  - unzip/zip/m4/pkg-config/python3 : standard Bazel/rules_foreign_cc needs.
# Versions are taken from jammy-updates at build time; pin exact .debs only if
# you need bit-reproducible *images* (the Bazel build itself stays reproducible
# given the same sources + .bazelrc).
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
        build-essential \
        gcc-10 \
        g++-10 \
        make \
        git \
        curl \
        unzip \
        zip \
        bzip2 \
        xz-utils \
        m4 \
        perl \
        pkg-config \
        zlib1g-dev \
        python3 \
        lld \
    && rm -rf /var/lib/apt/lists/*

# Make gcc/g++/cc/c++ point at GCC 10 — exactly what tests.yml does.
RUN update-alternatives --install /usr/bin/gcc gcc /usr/bin/gcc-10 30 \
 && update-alternatives --install /usr/bin/g++ g++ /usr/bin/g++-10 30 \
 && update-alternatives --install /usr/bin/cc cc /usr/bin/gcc 30 \
 && update-alternatives --set cc /usr/bin/gcc \
 && update-alternatives --install /usr/bin/c++ c++ /usr/bin/g++ 30 \
 && update-alternatives --set c++ /usr/bin/g++

ENV CC=/usr/bin/gcc-10 \
    CXX=/usr/bin/g++-10 \
    PATH=/usr/local/bin:$PATH \
    BAZELISK_HOME=/bazel-cache/bazelisk \
    BAZEL_CACHE_ROOT=/bazel-cache \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8

# bazelisk (multi-arch: linux-amd64 / linux-arm64 assets verified).
# It honours .bazelversion in the workspace; the repo's file is copied in so
# the smoke test has a single source of truth. The downloaded Bazel lands in
# /tmp (BAZELISK_HOME is overridden — /bazel-cache is overlaid at run time,
# so baking it here would be dead weight).
COPY .bazelversion /tmp/.bazelversion
RUN curl -fsSL -o /usr/local/bin/bazelisk \
        "https://github.com/bazelbuild/bazelisk/releases/download/${BAZELISK_VERSION}/bazelisk-linux-${TARGETARCH}" \
 && chmod +x /usr/local/bin/bazelisk \
 && ln -sf /usr/local/bin/bazelisk /usr/local/bin/bazel \
 && cd /tmp && BAZELISK_HOME=/tmp/bazelisk-smoke bazel version \
 && rm -rf /tmp/.bazelversion /tmp/bazelisk-smoke

# -----------------------------------------------------------------------------
FROM toolchain AS builder

ARG TYPESENSE_VERSION=nightly
ARG BAZEL_JOBS=6
# Keep .bazelrc's --jobs=6 unless overridden; explicit CLI flag wins over .bazelrc.

WORKDIR /src
COPY . .

# /bazel-cache (BuildKit cache mount) holds bazelisk's downloads, the
# repository/external caches and all action outputs, so a rebuild after a
# source change only recompiles what changed. Use the same path as a named
# volume when running the image directly (see docker/tsbuild.sh).
RUN --mount=type=cache,target=/bazel-cache \
    bazel --output_user_root=/bazel-cache build \
      --jobs=${BAZEL_JOBS} \
      --define=TYPESENSE_VERSION=\"${TYPESENSE_VERSION}\" \
      --verbose_failures \
      @com_google_protobuf//:protobuf_headers \
      @com_google_protobuf//:protobuf_lite \
      @com_google_protobuf//:protobuf \
      @com_google_protobuf//:protoc

RUN --mount=type=cache,target=/bazel-cache \
    bazel --output_user_root=/bazel-cache build \
      --jobs=${BAZEL_JOBS} \
      --define=TYPESENSE_VERSION=\"${TYPESENSE_VERSION}\" \
      --verbose_failures \
      //:typesense-server \
 && mkdir -p /out \
 && cp -L /src/bazel-bin/typesense-server /out/typesense-server

# -----------------------------------------------------------------------------
FROM builder AS test

ARG TYPESENSE_VERSION=nightly
ARG BAZEL_JOBS=6

RUN curl -fsSL https://dl.typesense.org/ci/tyrec/tyrec-1-models.tar.gz \
      -o test/resources/models.tar.gz

RUN --mount=type=cache,target=/bazel-cache \
    bazel --output_user_root=/bazel-cache test \
      --jobs=${BAZEL_JOBS} \
      --cache_test_results=no --test_output=all --test_timeout=900 \
      --define=TYPESENSE_VERSION=\"${TYPESENSE_VERSION}\" \
      //:typesense-test

# -----------------------------------------------------------------------------
# Shared production content; runtime / runtime-prebuilt differ only in their
# binary COPY line.
FROM ubuntu:${UBUNTU_VERSION} AS runtime-base

RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl \
 && rm -rf /var/lib/apt/lists/*

EXPOSE 8108
STOPSIGNAL SIGINT
# Port 8108 is hardcoded: a custom --api-port yields perpetual unhealthy.
# /health returns 200 even when degraded with resource_error — this is a
# liveness check, not a readiness gate.
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
    CMD curl -fsS http://127.0.0.1:8108/health || exit 1

ENTRYPOINT ["/opt/typesense-server"]

# -----------------------------------------------------------------------------
FROM runtime-base AS runtime
# Hermetic release path: binary from the builder stage (full rebuild).
COPY --from=builder /out/typesense-server /opt/typesense-server
RUN chmod +x /opt/typesense-server

# -----------------------------------------------------------------------------
FROM runtime-base AS runtime-prebuilt
# Dev/iteration path (tsbuild.sh dist-fast): binary from the build context.
COPY typesense-server /opt/typesense-server
RUN chmod +x /opt/typesense-server