# SIZES — snapshot shake-down measurements

Snapshot size is THE cost lever: it drives launch read ($0.00155/GB), suspend
write ($0.0038/GB), monthly storage ($0.08/GB-mo) **and** the COW-fault count on resume. So we
measure site-packages + venv **before and after** `shrink.sh`, per variant.

## How the numbers are produced (live)

`images/shrink.sh` runs inside the `py-builder` stage and prints, to the build log, a block:

```
SIZES :: variant=<v> :: site-packages=<path>
BEFORE  site-packages=<du -sh>  venv=<du -sh>
BEFORE  .so=<n>  .py=<n>  .pyc=<n>  .a=<n>
... (prune / matplotlib shake / compileall / strip) ...
AFTER   site-packages=<du -sh>  venv=<du -sh>
AFTER   .so=<n>  .py=<n>  .opt2=<n>  .a=<n>
SAVINGS site-packages: <before> -> <after>   venv: <before> -> <after>
```

To capture for the record from a real arm64 build (AWS server-side, or local with binfmt):

```bash
docker buildx build --platform linux/arm64 --progress=plain \
    -f microvm/images/Dockerfile.sci ./microvm 2>&1 | grep -A12 '^.*SIZES ::'
```

Then paste the BEFORE/AFTER lines into the table below.

## MEASURED — local arm64 build (2026-06-23, buildx linux/arm64, all guards passed)

Final container image sizes (`docker image inspect … .Size`, uncompressed) and the
`shrink.sh` deltas captured from the real build logs. These mirror the AWS Graviton
build (same Dockerfiles/shrink.sh). The big absolute lever turned out to be the
standalone CPython under `/opt/python` (full stdlib + static libpython + headers),
which the original shrink.sh never touched — now slimmed 92 MiB → 74 MiB per variant.

| variant | final image | site-packages (before→after) | venv (before→after) | /opt/python (before→after) |
|---------|-------------|------------------------------|----------------------|-----------------------------|
| base    | **66.4 MB** | 28K → 12K (stdlib in /opt/python) | 108K → 92K | 92M → 74M |
| mpl     | **98.1 MB** | (numpy+matplotlib, shaken)   | —                    | 92M → 74M |
| sci     | **107.2 MB**| 178M → 120M                  | 179M → 120M          | 92M → 74M |

Notes:
- The `/opt/python` slim (remove static libpython*.a + headers + unused stdlib:
  test/idlelib/tkinter/turtledemo/lib2to3/ensurepip/pydoc_data; strip all .so) is
  ~18 MiB/variant and is what makes the **base** snapshot small.
- matplotlib font allowlist keeps `DejaVu*` **and** `LastResort*` (font_manager loads
  the LastResort fallback unconditionally — dropping it broke the render guard).
- `pandas/_testing` is a RUNTIME module (kept); only `pandas/tests` is dropped.
- warm-parent VmRSS (suspend-snapshot driver) still TBD — capture from a running microVM.

## Memory snapshot vs. on-disk

The shake-down shrinks the **image/clean snapshot** (launch read + storage). The **suspend
snapshot** additionally captures the warm fork-server's **resident set** (pre-imported libs).
Keeping the parent single-threaded (no BLAS thread pools via `*_NUM_THREADS=1`) and importing
**only what the variant uses** keeps that RSS — and therefore suspend-write GB and resume COW
faults — minimal.

### Real snapshot sizes (AWS, authoritative)

The build records the actual snapshot byte-sizes — they live on the **build** record, not the image
version:

```bash
arn=arn:aws:lambda:<region>:<acct>:microvm-image:microvm-bench-<variant>
ver=$(aws lambda-microvms get-microvm-image --image-identifier "$arn" --query latestActiveImageVersion --output text)
bid=$(aws lambda-microvms list-microvm-image-builds --image-identifier "$arn" --image-version "$ver" --query 'items[0].buildId' --output text)
aws lambda-microvms get-microvm-image-build --image-identifier "$arn" --image-version "$ver" --build-id "$bid" --query snapshotBuild
```

Measured (us-east-1 v3.0; us-west-2 v1.0 is within ~4%):

| variant | memorySnapshot | codeInstall | diskSnapshot |
|---------|---------------:|------------:|-------------:|
| base    | 412 MiB        | 386 MiB     | 24 MiB       |
| mpl     | 511 MiB        | 526 MiB     | 22 MiB       |
| sci     | 552 MiB        | 572 MiB     | 22 MiB       |

- **memorySnapshot** — the warm fork-server's resident set + kernel pages dirtied at boot (the RSS
  this section is about). It drives suspend-write GB and resume restore: at AWS's ~1 s / 500 MB
  resume heuristic, base ≈ 0.8 s and sci ≈ 1.1 s — consistent with the measured warm-resume
  latencies (base ~0.7 s, sci ~1.4 s).
- **codeInstall** — the installed container filesystem (AL2023 base + `/opt/python` + venv); the
  authoritative on-disk size (the local `docker image .Size` above measures layers differently).
- **diskSnapshot** — bytes written during boot, excluding `codeInstall`.
