# syntax=docker/dockerfile:1
# =============================================================================
# Typesense (fork cmigazzi, v31) — pipeline de build et de packaging.
#
# Stages :
#   toolchain : image de builder réutilisable (ubuntu 22.04 + GCC 10 + bazelisk + lld).
#               Build isolé :  docker build --target toolchain -t typesense-builder .
#   deps      : ne compile QUE les dépendances externes du graphe Bazel (rocksdb,
#               onnx_runtime, icu, brpc, ...) et fige l'output base /bazel-cache
#               dans une couche d'image, réutilisée d'un run à l'autre.
#   builder   : FROM deps — copie le dépôt, recompile les TU serveur et link
#               //:typesense-server (deps récupérées via HTTPS avec un bundle CA
#               jammy à jour).
#   test      : builder + suite de tests C++ (//:typesense-test), fixture de
#               modèles tyrec-1 incluse, en miroir de .github/workflows/tests.yml.
#   runtime-base : contenu de production partagé (image de base, ca-certificates
#               + curl, EXPOSE/STOPSIGNAL/HEALTHCHECK/ENTRYPOINT). Tourne en root
#               par défaut, comme l'upstream typesense/typesense.
#   runtime   : image de production, drop-in de docker/deployment.Dockerfile
#               (+ HEALTHCHECK). Binaire issu du stage builder — le chemin de
#               release hermétique.
#   runtime-prebuilt : même image, binaire pris dans le contexte de build
#               (docker/tsbuild.sh dist-fast). Ne diffère de `runtime` QUE par la
#               ligne COPY du binaire.
#
# Justification de la toolchain : GCC 10.5 / ubuntu:22.04 reproduit la CI
# (.github/workflows/tests.yml installe g++-10 + lld sur ubuntu-22.04), donc les
# cinq incompatibilités GCC 13/14/15 sont absentes et la config .bazelrc
# `build:modern-gcc` n'est simplement pas nécessaire ici.
#
# La version de Bazel n'est volontairement PAS figée ici : bazelisk lit le
# .bazelversion du dépôt (= 6.2.0).
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
FROM toolchain AS deps
# Couche de dépendances. La compilation des ~40 dépôts externes (rocksdb,
# onnx_runtime, icu, brpc, jemalloc, ...) représente 2 à 3 heures : elle est
# isolée ici pour vivre dans une COUCHE d'image et non dans un
# `--mount=type=cache`. BuildKit n'exporte jamais le contenu d'un cache mount
# via `cache-to` (seules les couches le sont), donc en CI chaque run repartait
# d'un /bazel-cache vide et recompilait tout à froid ; ici l'état chaud est du
# contenu de couche, réutilisable d'un run à l'autre.
#
# Aucun ARG n'est déclaré dans ce stage, volontairement : il ne doit dépendre
# d'aucun build-arg. `--define=TYPESENSE_VERSION` n'entre dans aucune clé
# d'action des dépendances (seuls leurs consommateurs rejouent), donc un
# nouveau tag d'image réutilise cette couche telle quelle.
#
# Seuls les fichiers du graphe Bazel sont copiés. Les cibles foreign_cc de
# bazel/*.BUILD prennent leur lib_source dans leur propre dépôt externe
# (bazel/rocksdb.BUILD:44, onnxruntime.BUILD:218, icu/BUILD:22,
# openssl3.BUILD:35, curl.BUILD:42, s2geometry/BUILD:39, ...) : les seules
# entrées du dépôt principal dans leurs clés d'action sont WORKSPACE, .bazelrc,
# .bazelversion, BUILD et bazel/**. Copier src/ ou include/ n'ajouterait donc
# aucune dépendance utile et invaliderait la couche à chaque commit applicatif.
#
# L'output base reste à son chemin absolu d'origine, /bazel-cache/<hash de
# /src>, et `builder` en hérite par `FROM deps` : pas de `COPY --from` ni de
# déplacement de l'output base, pour que les chemins d'action ne dérivent
# jamais.
WORKDIR /src
COPY .bazelversion .bazelrc WORKSPACE BUILD /src/
COPY bazel /src/bazel

# --jobs est figé ici : le nombre de jobs n'entre dans aucune clé d'action, donc
# BAZEL_JOBS reste libre côté builder/CI sans invalider cette couche. En
# revanche les -jN des build_args/args de bazel/{rocksdb,curl,jemalloc,whisper,
# onnxruntime,snowball}.BUILD sont dans la ligne de commande des builds
# foreign_cc : ils font partie des clés d'action et ne doivent pas bouger.
RUN bazel --output_user_root=/bazel-cache build --jobs=4 --verbose_failures \
      @com_google_protobuf//:protobuf_headers \
      @com_google_protobuf//:protobuf_lite \
      @com_google_protobuf//:protobuf \
      @com_google_protobuf//:protoc

RUN bazel --output_user_root=/bazel-cache build --jobs=4 --verbose_failures \
      //:common_deps //:linux_deps

# Sandboxes d'action et logs de commande ne servent plus une fois la couche
# figée, et pèsent lourd.
RUN rm -rf /bazel-cache/*/sandbox \
 && rm -f /bazel-cache/*/java.log* /bazel-cache/*/command.log /bazel-cache/*/command.profile.gz

# -----------------------------------------------------------------------------
FROM deps AS builder
# Hériter de `deps` (plutôt que copier son output base) garde l'état Bazel chaud
# à son chemin absolu d'origine, et permet de supprimer le `--mount=type=cache`
# des stages builder et test : un tel mount masquerait la couche héritée et
# réintroduirait silencieusement le build à froid. Le bind mount
# $CACHE_DIR:/bazel-cache de docker/tsbuild.sh ne concerne que l'image
# `toolchain`, il ne s'applique jamais ici.

ARG TYPESENSE_VERSION=nightly
ARG BAZEL_JOBS=6
# Keep .bazelrc's --jobs=6 unless overridden; explicit CLI flag wins over .bazelrc.

WORKDIR /src
COPY . .

RUN bazel --output_user_root=/bazel-cache build \
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

RUN bazel --output_user_root=/bazel-cache test \
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