# syntax=docker/dockerfile:1.7
# =============================================================================
# microvm-bench image — variant: MPL  (CPython 3.13 + numpy + matplotlib)
#   baseline minimumMemoryInMiB = 1024  (set server-side in create-microvm-image;
#   not a Docker concern — see images/BUILD-NOTES.md)
#
# Build context root MUST be microvm/  (so COPY manager/ forkserver/ resolve):
#   docker buildx build --platform linux/arm64 \
#       -f images/Dockerfile.mpl -t microvm-bench-mpl ./microvm
#
# AWS builds this server-side on Graviton (ARM64). Multi-stage, snapshot-optimized
# per images/BUILD-NOTES.md. Only prebuilt manylinux/arm64 wheels — no compilers in final.
# =============================================================================

# -----------------------------------------------------------------------------
# Stage 1: Rust builder — compile the manager (ENTRYPOINT) to a release binary.
# -----------------------------------------------------------------------------
FROM --platform=linux/arm64 rust:1.96-bookworm AS manager-builder
WORKDIR /build/manager

COPY manager/Cargo.toml manager/Cargo.lock* ./
COPY manager/src ./src
ENV CARGO_TERM_COLOR=never
RUN --mount=type=cache,target=/usr/local/cargo/registry \
    --mount=type=cache,target=/build/manager/target \
    RUSTFLAGS="-C strip=symbols -C opt-level=3" \
    cargo build --release --locked 2>/dev/null || \
    RUSTFLAGS="-C strip=symbols -C opt-level=3" cargo build --release ; \
    mkdir -p /out ; \
    bin="$(find target/release -maxdepth 1 -type f -executable \
            ! -name '*.so' ! -name '*.d' | head -n1)" ; \
    test -n "$bin" || { echo 'no manager binary produced' >&2; exit 1; } ; \
    cp "$bin" /out/microvm-manager ; \
    strip --strip-unneeded /out/microvm-manager || true

# -----------------------------------------------------------------------------
# Stage 2: Python builder — standalone CPython 3.13 via uv + numpy + matplotlib.
# -----------------------------------------------------------------------------
FROM --platform=linux/arm64 debian:bookworm-slim AS py-builder
COPY --from=ghcr.io/astral-sh/uv:0.7 /uv /usr/local/bin/uv
ENV UV_PYTHON_INSTALL_DIR=/opt/python \
    UV_LINK_MODE=copy \
    UV_PYTHON_PREFERENCE=only-managed
WORKDIR /app
# elfutils -> eu-strip (alignment-safe .so shake-down); binutils -> strip fallback.
RUN apt-get update && apt-get install -y --no-install-recommends binutils elfutils \
    && rm -rf /var/lib/apt/lists/*
RUN uv venv --python 3.13 /app/venv
ENV VIRTUAL_ENV=/app/venv \
    PATH=/app/venv/bin:$PATH

# ---- HARD snapshot shake-down (images/BUILD-NOTES.md): installs wheels + strips --------
# shrink.sh installs numpy+matplotlib (prebuilt arm64 wheels only), then runs
# compileall -O2/unchecked-hash, prunes tests/docs/stubs/sources, keeps only the
# Agg backend + DejaVu Sans, strips every .so, and prints du -sh before/after.
COPY images/shrink.sh /usr/local/bin/shrink.sh
RUN chmod +x /usr/local/bin/shrink.sh && MVB_VARIANT=mpl /usr/local/bin/shrink.sh

# -----------------------------------------------------------------------------
# Stage 3: Final — snapshot-safe AL2023 minimal base (patched OpenSSL).
# -----------------------------------------------------------------------------
FROM --platform=linux/arm64 public.ecr.aws/lambda/microvms:al2023-minimal AS final

# Snapshot/thread hygiene + variant identity (images/BUILD-NOTES.md levers 6 & 7).
# Single-thread every BLAS/OpenMP pool so the warm parent stays single-threaded
# (fork-safe) AND small; Agg is the only matplotlib backend shipped.
ENV OPENBLAS_NUM_THREADS=1 \
    OMP_NUM_THREADS=1 \
    MKL_NUM_THREADS=1 \
    NUMEXPR_NUM_THREADS=1 \
    MPLBACKEND=Agg \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    MVB_VARIANT=mpl \
    FORKSERVER_PY=/app/forkserver/forkserver.py \
    VIRTUAL_ENV=/app/venv \
    PATH=/app/venv/bin:/var/lang/bin:/usr/local/bin:/usr/bin:/bin

WORKDIR /app

# Standalone CPython under /opt/python + the venv that symlinks into it.
COPY --from=py-builder /opt/python /opt/python
COPY --from=py-builder /app/venv  /app/venv

# Manager binary (ENTRYPOINT) + Python fork-server + samples.
COPY --from=manager-builder /out/microvm-manager /usr/local/bin/microvm-manager
COPY forkserver/forkserver.py /app/forkserver/forkserver.py
COPY samples/ /app/samples/

EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/microvm-manager"]
