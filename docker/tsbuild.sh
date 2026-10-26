#!/usr/bin/env bash
# Typesense (v31 fork) container build helper.
#
# Usage:
#   docker/tsbuild.sh image [TYPESENSE_VERSION]     # build toolchain image
#   docker/tsbuild.sh server [TYPESENSE_VERSION]    # build just typesense-server (incremental)
#   docker/tsbuild.sh test [TYPESENSE_VERSION]      # run C++ test suite //:typesense-test
#   docker/tsbuild.sh shell                         # interactive shell w/ mounted repo
#   docker/tsbuild.sh dist [TYPESENSE_VERSION]      # production image (hermetic full rebuild)
#   docker/tsbuild.sh dist-fast [TYPESENSE_VERSION] # production image (reuses ./bazel-bin)
#   docker/tsbuild.sh multiarch VERSION IMAGE_REF   # buildx amd64+arm64, --push
#
# Notes:
#  - The source tree is bind-mounted, so Bazel writes bazel-bin/ bazel-out/
#    bazel-testlogs/ + external-* into ./ — all covered by .gitignore (/bazel-*).
#  - The bazel cache is a user-owned host dir (~/.cache/typesense-bazel), so
#    the --user container can write it; it persists across builds.
#  - Stale residue from the previous script version (named volume, no --user)
#    breaks this script with confusing permission errors; clean it up once:
#      sudo rm -rf bazel-bin bazel-out bazel-testlogs bazel-typesense \
#                  external-* ~/.cache/typesense-bazel
#  - dist vs dist-fast: dist is the hermetic release path (BuildKit cache
#    mount inside the builder stage — a full ~40-dep rebuild if that store is
#    cold, even after a host-cache `server` build). dist-fast stages
#    ./bazel-bin/typesense-server into a temp context and builds the
#    runtime-prebuilt stage, reusing the host-cache incremental build — the
#    dev/iteration path. NEITHER runs the test suite (the Dockerfile `test`
#    stage is never built by them); run `docker/tsbuild.sh test` separately,
#    or rely on CI.
#  - Runtime data-dir ownership: the image runs as uid 1000720000 (the
#    predecessor docker/deployment.Dockerfile ran as root). An existing
#    root-owned --data-dir volume fails at startup ("Data directory ... does
#    not exist", src/typesense_server_utils.cpp:519). Migrate with:
#      chown -R 1000720000:1000720000 <volume>
#  - multiarch is NOT a first-run path. The arm64 leg runs under QEMU
#    emulation on amd64 hosts — slow and flaky for the heavily-threaded
#    autotools/cmake foreign builds (down-tuned to --jobs=2 below). Prefer
#    building arm64 natively on an arm64 runner with a separate
#    `--platform linux/arm64` invocation. The shared BuildKit cache-mount id
#    across platforms also causes concurrent-Bazel lock contention on one
#    output root, so run platform builds sequentially.
set -euo pipefail

cd "$(dirname "$0")/.."

BUILDER_IMAGE=typesense-builder:v31-gcc10
BUILDER_DOCKERFILE=docker/Dockerfile
# Host dir (not a named volume): mkdir'd here, so it is owned by the invoking
# user and writable by the container running as that same --user uid. Docker
# auto-creates missing bind-mount sources as root, hence the mkdir -p MUST run
# before docker run. No manual/root steps on a fresh machine.
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/typesense-bazel"
mkdir -p "$CACHE_DIR"
# HOME=/tmp: the mounted /etc/passwd resolves $HOME to a host path that does
# not exist inside the image; keep it writable for third-party build scripts.
# No --network host: dep fetches are outbound HTTPS (bridge NAT suffices) and
# bazel test binds test servers on container-local loopback; host networking
# breaks on Docker Desktop/rootless and lets :8108 fixtures collide with the
# host.
RUNFLAGS=(--rm -e HOME=/tmp -e LANG=C.UTF-8 -e LC_ALL=C.UTF-8 -v "$PWD:/src" -v "$CACHE_DIR:/bazel-cache"
          --user "$(id -u):$(id -g)"
          -v /etc/passwd:/etc/passwd:ro -v /etc/group:/etc/group:ro
          -w /src)

VERSION="${2:-nightly}"

# Only `image` creates the builder image; fail with a clear message instead of
# docker's "Unable to find image" pull attempt on a fresh checkout.
need_builder() {
  docker image inspect "$BUILDER_IMAGE" >/dev/null 2>&1 || {
    echo "error: builder image $BUILDER_IMAGE not found." >&2
    echo "       run 'docker/tsbuild.sh image' first." >&2
    exit 1
  }
}

cmd="${1:-help}"
case "$cmd" in
  image)
    docker build --target toolchain -f "$BUILDER_DOCKERFILE" -t "$BUILDER_IMAGE" . ;;
  server|test|shell)
    need_builder
    if [ "$cmd" = server ]; then
      docker run "${RUNFLAGS[@]}" "$BUILDER_IMAGE" \
        bazel --output_user_root=/bazel-cache build --verbose_failures \
        --define=TYPESENSE_VERSION=\"${VERSION}\" //:typesense-server
    elif [ "$cmd" = test ]; then
      # Temp file + gzip sanity check + mv: never keep (or re-trust) a stale
      # or partially-downloaded tarball.
      if [ ! -f test/resources/models.tar.gz ] || \
         ! tar -tzf test/resources/models.tar.gz >/dev/null 2>&1; then
        curl -fsSL https://dl.typesense.org/ci/tyrec/tyrec-1-models.tar.gz \
          -o test/resources/models.tar.gz.tmp
        mv test/resources/models.tar.gz.tmp test/resources/models.tar.gz
      fi
      # Single bazel test: it builds //:typesense-test itself.
      docker run "${RUNFLAGS[@]}" "$BUILDER_IMAGE" \
        bazel --output_user_root=/bazel-cache test \
        --verbose_failures \
        --cache_test_results=no --test_output=all --test_timeout=900 \
        --define=TYPESENSE_VERSION=\"${VERSION}\" //:typesense-test
    else
      docker run -it "${RUNFLAGS[@]}" "$BUILDER_IMAGE" bash
    fi ;;
  dist)
    docker build --target runtime -f "$BUILDER_DOCKERFILE" \
      --build-arg TYPESENSE_VERSION="${2:-nightly}" \
      -t "deleev-typesense:${2:-nightly}" . ;;
  dist-fast)
    # bazel-bin dangles on the host (it points at /bazel-cache/...), so copy
    # the binary out from inside the container instead of readlink -f'ing it.
    STAGE="$(mktemp -d)"
    trap 'rm -rf "$STAGE"' EXIT
    if ! docker run "${RUNFLAGS[@]}" -v "$STAGE:/staging" "$BUILDER_IMAGE" \
         bash -c 'cp -L /src/bazel-bin/typesense-server /staging/typesense-server'; then
      echo "error: could not copy typesense-server from bazel-bin." >&2
      echo "       run 'docker/tsbuild.sh server' first." >&2
      exit 1
    fi
    docker build --target runtime-prebuilt -f "$BUILDER_DOCKERFILE" \
      -t "deleev-typesense:${VERSION}" "$STAGE" ;;
  multiarch)
    VERSION="$2"; REF="$3"
    # BAZEL_JOBS=2: avoid --jobs=6 under QEMU emulation (see header note).
    docker buildx build --platform linux/amd64,linux/arm64 \
      --target runtime -f "$BUILDER_DOCKERFILE" \
      --build-arg TYPESENSE_VERSION="$VERSION" \
      --build-arg BAZEL_JOBS=2 \
      -t "$REF" --push . ;;
  help|*)
    sed -n '2,41p' "$0"; exit 1 ;;
esac