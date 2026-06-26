# microvm-bench — image build notes

Three ARM64, snapshot-optimized, multi-stage images. AWS builds them **server-side on
Graviton** via `create-microvm-image`; this directory only holds the Dockerfiles + the
`shrink.sh` shake-down. The `scripts/build-image.sh` runbook (other component) zips the
build context, uploads to S3, and calls `create-microvm-image` with the hook config below.

| variant | Dockerfile      | stack                              | baseline `minimumMemoryInMiB` |
|---------|-----------------|------------------------------------|-------------------------------|
| base    | `Dockerfile.base` | CPython 3.13 stdlib only          | **512**                       |
| mpl     | `Dockerfile.mpl`  | + numpy + matplotlib              | **1024**                      |
| sci     | `Dockerfile.sci`  | + pandas + seaborn (on numpy/mpl) | **1024**                      |

## Build context

The build context root is **`microvm/`** (one level above this dir) so the Dockerfiles can
`COPY manager/ … forkserver/ … samples/ … images/shrink.sh`. Local arm64 reproduction
(AWS does the real build):

```bash
docker run --privileged --rm tonistiigi/binfmt --install arm64   # once, registers qemu
docker buildx build --platform linux/arm64 \
    -f microvm/images/Dockerfile.mpl -t microvm-bench-mpl ./microvm
```

`# syntax=docker/dockerfile:1.7` is pinned at the top of each file so the BuildKit frontend
matches what AWS uses server-side.

## Stages (all three Dockerfiles)

1. **`manager-builder`** (`rust:1.96-bookworm`, arm64): `cargo build --release --locked`
   the Rust manager → strip → `/out/microvm-manager`. Cargo registry + target are
   `--mount=type=cache` so AWS rebuilds are warm. Falls back to a non-`--locked` build if the
   lockfile is absent. Binary name is resolved dynamically and canonicalized to
   `microvm-manager` (the name the ENTRYPOINT and this doc pin).
2. **`py-builder`** (`debian:bookworm-slim`, arm64): `uv` installs a **managed standalone
   CPython 3.13** (`python-build-standalone`) under `/opt/python` and creates `/app/venv`.
   `images/shrink.sh` then installs the variant's **prebuilt arm64 wheels only**
   (`uv pip install --only-binary=:all:`) and runs the full snapshot shake-down (see below).
   No compilers/headers reach the final image (`binutils` is builder-only, for `strip`).
3. **`final`** (`public.ecr.aws/lambda/microvms:al2023-minimal`, the snapshot-safe AL2023
   base with patched OpenSSL): copies `/opt/python` + `/app/venv` + the manager binary +
   `forkserver/forkserver.py` + `samples/`. `ENTRYPOINT = /usr/local/bin/microvm-manager`.
   `EXPOSE 8080`.

## HARD snapshot optimization (`shrink.sh`)

Runs in `py-builder` before the venv is copied to `final`. Levers, in order:

- **compileall** `-f -o2 --invalidation-mode unchecked-hash` over **all** site-packages;
  keep **only** `*.opt-2.pyc` (delete `.pyc` / `.opt-1.pyc` levels), then delete every `.py`
  whose `*.opt-2.pyc` sibling exists. `unchecked-hash` lets the loader trust bytecode without
  statting the (now-deleted) source; `-o2` strips docstrings + asserts.
- **prune dead weight**: `*/tests/`, `*/test/`, `docs/`, `examples/`, `*.pyi`, `*.pyx`,
  `*.pxd`, `*.c`, `*.h`, `*.cpp`, Fortran sources, `*.a`; numpy/pandas bundled tests.
- **matplotlib**: keep **only the Agg backend** (+ the file writers pdf/ps/svg/pgf and the
  template) and **one font, DejaVu Sans**; drop `sample_data`, afm/pdfcorefonts, GUI backends.
- **strip** `--strip-unneeded` every `.so` (big win on bundled OpenBLAS/LAPACK) in both
  site-packages and the standalone CPython; delete `*.a`.
- Prints `du -sh` of site-packages + venv **before and after** → captured in `SIZES.md`.

Runtime env baked into `final` keeps the warm fork-server parent single-threaded (fork-safe)
and small: `OPENBLAS_NUM_THREADS=1 OMP_NUM_THREADS=1 MKL_NUM_THREADS=1
NUMEXPR_NUM_THREADS=1 MPLBACKEND=Agg PYTHONDONTWRITEBYTECODE=1`, plus identity/wiring
`MVB_VARIANT=<variant>` and `FORKSERVER_PY=/app/forkserver/forkserver.py`.

## Server-side `create-microvm-image` hook config (REQUIRED)

Per API-FACTS.md: hook flags are the string enum `"ENABLED" | "DISABLED"`; all enabled hooks
share the single `hooks.port`; timeouts are 1–3600 s. The manager serves every hook on the
fixed base path `/aws/lambda-microvms/runtime/v1/{ready,validate,run,resume,suspend,terminate}`
(CONTRACTS §C). **Enable all six**, all on **port 9000** (the hooks channel — NOT 8080, the
data-plane `/exec` default; the manager binds both):

```jsonc
"hooks": {
  "port": 9000,                              // hooks channel (manager also binds 8080 for /exec)
  "microvmImageHooks": {
    "ready":    "ENABLED", "readyTimeoutInSeconds":    60,   // 200 once fork-server warm + first child pre-forked
    "validate": "ENABLED", "validateTimeoutInSeconds": 60    // runs ONE mock exec to prefetch hot snapshot regions
  },
  "microvmHooks": {
    "run":       "ENABLED", "runTimeoutInSeconds":       30, // re-arm socket+child, stamp t_run_done; traffic starts after 200
    "resume":    "ENABLED", "resumeTimeoutInSeconds":    30, // re-establish UDS/sockets, pre-fork fresh child
    "suspend":   "ENABLED", "suspendTimeoutInSeconds":   15, // drain child, flush before checkpoint
    "terminate": "ENABLED", "terminateTimeoutInSeconds": 15  // final flush
  }
}
```

Other `create-microvm-image` fields the runbook supplies (names per API-FACTS / CONTRACTS):
- `name`: `microvm-bench-<variant>`  (→ ARN `arn:aws:lambda:<region>:<acct>:microvm-image:microvm-bench-<variant>`)
- `baseImageArn`: `arn:aws:lambda:<region>:aws:microvm-image:al2023-1`
- `buildRoleArn`: `microvm-bench-build-role` (required for build logs)
- `codeArtifact.uri`: `s3://microvm-bench-artifacts-<region>-<acct>/<variant>/context.zip`
- `cpuConfigurations`: `[{ "architecture": "ARM_64" }]`  (ARM_64 only)
- `resources`: `[{ "minimumMemoryInMiB": 512 }]` (base) or `1024` (mpl/sci) — **the cost knob**
- `egressNetworkConnectors`: `[ INTERNET_EGRESS ]` at **build time** so `uv` can pull wheels
- `tags`: `{ "Project": "microvm-bench" }` (reaper + cost allocation)

> `additionalOsCapabilities` is omitted (only legal value is `["ALL"]`; we need nothing extra).
> The `validate` hook is enabled precisely so the build samples the warm snapshot's hot pages
> (measured with/without). `/ready` and `/validate` must return **503
> immediately** (never hold the socket) until warm, or Lambda kills the build.

## Verification done in this component

`docker buildx build --check` was run on each Dockerfile (parse + lint, no execution). The
real AL2023 **microvms** base (`public.ecr.aws/lambda/microvms:al2023-minimal`) is an
arm64-only GA image whose manifest does **not resolve in this WSL/x86 dev env** ("no match for
platform in manifest") — an environment limitation, not a Dockerfile defect. To exercise the
linter over every instruction, the check was re-run with the final-stage base swapped to the
resolvable sibling `public.ecr.aws/amazonlinux/amazonlinux:2023-minimal` (the only diff is that
one `FROM` line); result for all three: **"Check complete, no warnings found."** AWS resolves
the real base server-side at build time.
