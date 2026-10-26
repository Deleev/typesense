# Build and test runbook (Docker only)

Scope: this covers building, testing, and packaging Typesense from a plain checkout using nothing but Docker. Assumed: a clone of this repository and a working Docker daemon (with `buildx` only for `multiarch`). No host Bazel, no host compiler, no system packages. All commands run through `docker/tsbuild.sh`, which wraps the stages in `docker/Dockerfile`. Bazel itself is never installed on the host; the `toolchain` stage image (`typesense-builder:v31-gcc10`) carries bazelisk, which honors `.bazelversion` (6.2.0).

## Quick start

```bash
docker/tsbuild.sh image        # build the toolchain/builder image (typesense-builder:v31-gcc10)
docker/tsbuild.sh server 31.0  # build //:typesense-server (incremental, ~40 deps fetched and compiled)
docker/tsbuild.sh test 31.0    # run //:typesense-test (downloads test/resources/models.tar.gz if missing)
```

The second argument is `TYPESENSE_VERSION`, baked into the binary via `--define=TYPESENSE_VERSION=...`; if omitted it defaults to `nightly`. Use the same value for `server` and `test`.

After `server`, the binary lives under the Bazel cache, not in the repo tree (see "Gotchas", item 3):

```bash
~/.cache/typesense-bazel/*/execroot/__main__/bazel-out/k8-fastbuild/bin/typesense-server
```

## Interactive shell

```bash
docker/tsbuild.sh shell
```

Drops you into a bash shell in the container with the repo mounted at `/src` and the cache at `/bazel-cache`. From there you can run `bazel` by hand — keep the locale env vars intact (see item 2) and mirror the wrapper's flags:

```bash
bazel --output_user_root=/bazel-cache test \
  --cache_test_results=no --test_output=all --test_timeout=900 \
  --define=TYPESENSE_VERSION=\"31.0\" \
  --test_arg=--gtest_filter='Collection.*' //:typesense-test
```

## Production image

```bash
docker/tsbuild.sh dist 31.0        # deleev-typesense:31.0, hermetic full rebuild
docker/tsbuild.sh dist-fast 31.0   # same image, reuses the binary from a prior `server` build
```

- `dist` targets the `runtime` stage and re-runs the whole builder stage. It uses a BuildKit cache mount for `/bazel-cache`; if that store is cold, it is a full ~40-dependency recompile even if the host cache from `server` is warm. It does not run the tests.
- `dist-fast` targets `runtime-prebuilt`: it copies `bazel-bin/typesense-server` into a temp context and builds the runtime image without recompiling. It does not run the tests either; run `docker/tsbuild.sh test` separately, or rely on CI (`.github/workflows/tests.yml`).

Running the image:

```bash
docker run -d -p 8108:8108 -v typesense-data:/data deleev-typesense:31.0 --data-dir /data
docker stop --stop-timeout 60 <container>
```

The image runs as root (uid 0), matching the upstream `typesense/typesense` image, so both the named-volume recipe above and root-owned bind mounts (e.g. `-v …:/var/lib/typesense/data`) work as-is — no `chown` or `user:` override needed.

`STOPSIGNAL SIGINT` triggers a graceful flush; pass `--stop-timeout 60` or Docker kills it after the 10s default.

Multiarch (not routine, see item 12):

```bash
docker/tsbuild.sh multiarch 31.0 <registry>/<org>/typesense:31.0
```

Builds amd64+arm64 via `docker buildx --platform linux/amd64,linux/arm64 --push`.

## Gotchas

1. **GCC 10.5 is deliberate.** The `toolchain` stage installs `gcc-10`/`g++-10` on `ubuntu:22.04` and points `gcc`/`g++`/`cc`/`c++` at them via `update-alternatives`, exactly like CI. This codebase does not build on GCC 13/14/15; do not "upgrade" the compiler.
2. **`LANG=C.UTF-8` / `LC_ALL=C.UTF-8` are load-bearing.** They are set both in the image and in the wrapper's run flags. Bazel 6.2.0 embeds JDK 11; without a UTF-8 locale `sun.jnu.encoding` becomes `ANSI_X3.4-1968` and any non-ASCII path in a dependency fails with `No such file or directory` while digesting inputs (onnxruntime ships such files, e.g. `winml/test/collateral/models/UnicodePath/こんにちは maçã/foo.onnx`). If you run `bazel` by hand in `shell`, keep the locale.
3. **`bazel-bin`, `bazel-out`, `bazel-testlogs` (and `bazel-src`) in the repo are dangling on the host.** They are created inside the container pointing at `/bazel-cache/...`, which is bind-mounted from `~/.cache/typesense-bazel` on the host. This is expected, not corruption. Read artifacts from `~/.cache/typesense-bazel/*/execroot/__main__/...`.
4. **The test suite is big: 1,697 gtest cases across 70 suites, roughly 7-10 minutes, dominated by the `Collection*` fixtures.** `BUILD`'s `cc_test(typesense-test)` compiles at `-O0` by default; pass `--define=mode=release` for `-O2` — much faster, but note it tests a differently-optimized binary.
5. **`--test_timeout=900` is required.** The target declares no `size`/`timeout`, so Bazel defaults to `moderate` (300s), which truncates the suite about 72% in and reports a misleading `TIMEOUT`. The wrapper passes 900; a hand-run `bazel test` must too.
6. **Filter with `--test_arg=--gtest_filter='Fixture.Case'`, not `--test_filter`.** `test/main.cpp` calls `::testing::InitGoogleTest` directly, so Bazel's `TESTBRIDGE_TEST_ONLY` path does not apply.
7. **Keep `--cache_test_results=no` on re-runs** or Bazel replays a cached verdict instead of executing the tests.
8. **New test files must sit flat in `test/`.** `test_src_files = glob(["test/*.cpp"])` does not recurse into subdirectories.
9. **`test/resources/models.tar.gz` is a declared test input.** `test_data_files` globs `test/resources/**` and `test/**/*.gz`, which is why the wrapper downloads the tyrec-1 models tarball before `test`. The same globs cover the tracked `test/resources/cgroup/**` fixture read by `test/system_metrics_test.cpp` — `.dockerignore` deliberately keeps it.
10. **The runtime image runs as root (uid 0), matching upstream `typesense/typesense`.** An earlier fork revision ran as a dedicated user (uid `1000720000`), which crash-looped on root-owned data volumes ("Data directory ... does not exist", `src/typesense_server_utils.cpp:519`). That contract is gone: no volume `chown` migration or docker-compose `user:` override is needed anymore; bind-mount the data dir directly.
11. **The healthcheck is liveness, not readiness, and the port is hardcoded.** `HEALTHCHECK` curls `http://127.0.0.1:8108/health` without an API key every 30s; `/health` returns 200 even when the node is degraded (e.g. with a `resource_error`), so a green check does not mean the node is searchable. If you start the server with a custom `--api-port`, the check probes 8108 anyway and the container reads perpetually unhealthy.
12. **`multiarch` is not a routine path.** On an amd64 host, the arm64 leg compiles ~40 C++ dependencies under QEMU — very slow and flaky for threaded autotools/CMake builds — hence the wrapper down-tunes it with `--build-arg BAZEL_JOBS=2`. Prefer a native arm64 runner with a separate `docker buildx build --platform linux/arm64` invocation.
13. **`dist` vs `dist-fast`:** `dist` is the hermetic release path (full builder-stage rebuild from a cold BuildKit cache, tests not run); `dist-fast` reuses the wrapper-built binary and produces the identical runtime image without recompiling. Neither runs the test suite.

## Troubleshooting

- **`error: builder image typesense-builder:v31-gcc10 not found`** — run `docker/tsbuild.sh image` first. Only that subcommand builds the builder image.
- **Suspect a corrupted/poisoned cache** — wipe it; the next build re-fetches and recompiles everything:
  ```bash
  rm -rf ~/.cache/typesense-bazel
  docker rmi typesense-builder:v31-gcc10
  ```
- **Confusing permission errors on a fresh-looking tree** — you may have residue from an older version of the wrapper (named volume, no `--user`), which ran the container as root. Clean once:
  ```bash
  sudo rm -rf bazel-bin bazel-out bazel-src bazel-testlogs bazel-typesense \
              external-* ~/.cache/typesense-bazel
  ```
- **Test run ends with `TIMEOUT` partway through the suite** — you dropped `--test_timeout=900`; Bazel's 300s `moderate` default truncates the run.
- **Re-run reports a green result in seconds** — you dropped `--cache_test_results=no`; Bazel replayed cached results.
- **`No such file or directory` during input digesting, mentioning a non-ASCII path** — the UTF-8 locale was lost; keep `LANG=C.UTF-8` / `LC_ALL=C.UTF-8`.
- **Server image crash-loops on a data volume** — only relevant to containers from the old uid-`1000720000` image revision; current images run as root like upstream `typesense/typesense`, so a root-owned volume works directly. If you still see "Data directory ... does not exist", check the `--data-dir` path and the volume mount.

## Out of scope

- **`api_tests/` (bun harness) is not wired into this Docker pipeline.** It is the fork's API-level suite: it spawns a real server via `TYPESENSE_BINARY_PATH`, needs `TYPESENSE_DATA_DIR`, runs single-node on 8108 and multi-node on 5108/6108/7108 with API key `xyz`, supports `--no-secrets` and per-file runs (`typesense-api-tests collections.test.ts`), and embedding tests need a TEI container on port 8080. It requires bun, so it is not docker-only today; CI runs it in `.github/workflows/tests.yml`.
- **The native (non-Docker) build** (e.g. on Fedora) is a separate, harder path that required patches for GCC 13/14/15 plus a `build:modern-gcc` config in `.bazelrc`. It is an acknowledged alternative, not the supported route.
