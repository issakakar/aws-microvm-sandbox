#!/usr/bin/env bash
# =============================================================================
# shrink.sh — HARD snapshot shake-down (see images/BUILD-NOTES.md)
#
# Runs INSIDE the py-builder stage of every variant Dockerfile, AFTER the venv
# exists and BEFORE the venv is copied into the final image. It:
#   1. installs the variant's wheels (prebuilt manylinux/arm64 only; no source).
#   2. compileall -O2 unchecked-hash over ALL site-packages, keeping only
#      *.opt-2.pyc; deletes other pyc levels and (safely) the compiled *.py.
#   3. deletes tests/docs/headers/sample-data; matplotlib -> Agg + DejaVu Sans only.
#   4. strip --strip-unneeded every .so; deletes *.a.
#   5. prints du -sh of site-packages BEFORE and AFTER (captured into SIZES.md).
#
# Variant is selected via $MVB_VARIANT (base|mpl|sci). Pins are intentionally
# loose-but-current; AWS resolves the latest matching arm64 wheels server-side.
#
# Idempotent and defensive: every destructive step is guarded so a missing path
# (e.g. base has no numpy) never fails the build.
# =============================================================================
set -euo pipefail

VENV="${VIRTUAL_ENV:-/app/venv}"
VARIANT="${MVB_VARIANT:?MVB_VARIANT must be set (base|mpl|sci)}"
PYBIN="$VENV/bin/python"
SITE="$("$PYBIN" -c 'import sysconfig; print(sysconfig.get_path("purelib"))')"

# --- which wheels per variant ------------------------------------------------
# Prebuilt arm64/manylinux wheels only (--only-binary=:all: forbids any source
# compile reaching the build, so the final image carries no toolchain).
WHEELS=()
case "$VARIANT" in
  base) WHEELS=() ;;                                   # stdlib only
  mpl)  WHEELS=(numpy matplotlib) ;;                   # charts
  sci)  WHEELS=(numpy matplotlib pandas seaborn) ;;    # dataframe viz (superset)
  *)    echo "unknown MVB_VARIANT=$VARIANT" >&2; exit 1 ;;
esac

if [ "${#WHEELS[@]}" -gt 0 ]; then
  echo ">> installing wheels ($VARIANT): ${WHEELS[*]}"
  # uv pip: fast, prebuilt-only. --no-cache keeps no wheel cache in the layer.
  uv pip install --python "$PYBIN" --no-cache --only-binary=:all: "${WHEELS[@]}"
fi

human() { du -sh "$1" 2>/dev/null | cut -f1; }
count() { find "$SITE" -name "$1" 2>/dev/null | wc -l | tr -d ' '; }

echo "============================================================"
echo "SIZES :: variant=$VARIANT :: site-packages=$SITE"
BEFORE_SP="$(human "$SITE")"
BEFORE_VENV="$(human "$VENV")"
echo "BEFORE  site-packages=$BEFORE_SP  venv=$BEFORE_VENV"
echo "BEFORE  .so=$(count '*.so')  .py=$(count '*.py')  .pyc=$(count '*.pyc')  .a=$(count '*.a')"

# --- (3) shake the heavies: tests / docs / headers / sources / sample data ---
echo ">> pruning tests, docs, headers, stubs, sources, sample-data"
# Directories that are pure dead weight at runtime.
find "$SITE" -type d \( \
       -name tests -o -name test -o -name testing \
    -o -name '__pycache__' \
    -o -name docs -o -name doc -o -name examples \
  \) -prune -exec rm -rf {} + 2>/dev/null || true

# File classes we never execute: type stubs, Cython/C sources, static archives,
# build leftovers. (*.pyc handled in the compileall step below.)
find "$SITE" -type f \( \
       -name '*.pyi' -o -name '*.pyx' -o -name '*.pxd' \
    -o -name '*.c'   -o -name '*.h'   -o -name '*.cpp' \
    -o -name '*.f'   -o -name '*.f90' \
    -o -name '*.a' \
  \) -delete 2>/dev/null || true

# numpy/pandas bundled tests live under the package too (belt + suspenders).
for pkg in numpy pandas scipy; do
  rm -rf "$SITE/$pkg/tests" "$SITE/$pkg"/*/tests 2>/dev/null || true
done

# --- matplotlib: keep Agg backend + ONE font (DejaVu Sans); drop sample_data --
MPL="$SITE/matplotlib"
MPLDATA="$SITE/matplotlib/mpl-data"
if [ -d "$MPL" ]; then
  echo ">> matplotlib shake: Agg only + DejaVu Sans only + drop sample_data"
  rm -rf "$MPLDATA/sample_data" 2>/dev/null || true
  # Fonts: keep the small DejaVu family (the default sans/serif/mono) AND
  # LastResort*.ttf — matplotlib's font_manager loads the LastResort fallback
  # UNCONDITIONALLY at import/render (missing it raises FileNotFoundError +
  # "tuple.index(x): x not in tuple"). Drop the heavier math fonts (STIX/cmr/cmsy)
  # — only needed for mathtext, which the bench samples do not use. Drop afm/pdf
  # core fonts (PDF/PS backends, not Agg).
  if [ -d "$MPLDATA/fonts" ]; then
    find "$MPLDATA/fonts/ttf" -type f \
      ! -name 'DejaVu*.ttf' \
      ! -name 'LastResort*.ttf' \
      -delete 2>/dev/null || true
    rm -rf "$MPLDATA/fonts/afm" "$MPLDATA/fonts/pdfcorefonts" 2>/dev/null || true
  fi
  # Backends: we render headless via Agg only. Remove GUI/interactive backend
  # modules (tk/qt/gtk/wx/web/macosx) — they pull nothing at runtime but are dead
  # weight in the snapshot. Keep agg, the cairo/pdf/ps/svg writers, and the base.
  if [ -d "$MPL/backends" ]; then
    find "$MPL/backends" -type f -name 'backend_*.py' \
      ! -name 'backend_agg.py' \
      ! -name 'backend_template.py' \
      ! -name 'backend_pdf.py' ! -name 'backend_ps.py' \
      ! -name 'backend_svg.py' ! -name 'backend_pgf.py' \
      ! -name 'backend_mixed.py' \
      -delete 2>/dev/null || true
    rm -rf "$MPL/backends/qt_editor" "$MPL/backends/web_backend" \
           "$MPL/backends/qt_compat.py" 2>/dev/null || true
  fi
  # matplotlib also ships its own tests + sample images.
  rm -rf "$MPL/tests" "$SITE/mpl_toolkits/tests" 2>/dev/null || true
fi

# pandas: drop the bundled TEST SUITE only. Do NOT remove pandas/_testing — despite
# the name it is a RUNTIME module (pandas/__init__.py -> pandas.testing ->
# pandas._testing), so deleting it raises ModuleNotFoundError on `import pandas`.
PD="$SITE/pandas"
if [ -d "$PD" ]; then
  rm -rf "$PD/tests" 2>/dev/null || true
fi

# --- (2) compileall -O2 unchecked-hash; convert to SOURCELESS legacy layout --
# unchecked-hash: the loader trusts the .pyc without statting the source — lets
# us delete the .py afterward and still import. -o2 strips docstrings + asserts.
#
# CRITICAL: a bytecode-only module is ONLY importable if the .pyc sits in the
# *legacy* location next to where the .py was (e.g. pkg/mod.pyc) — NOT in
# __pycache__. CPython consults __pycache__/<name>.cpython-XYZ[.opt-N].pyc ONLY
# when the matching .py source still exists. So we MOVE each opt-2 pyc out of
# __pycache__ to <module>.pyc, THEN delete the .py. (Verified: importing from
# __pycache__-only bytecode fails with ModuleNotFoundError at every -O level.)
echo ">> compileall -f -o2 --invalidation-mode unchecked-hash (all site-packages)"
"$PYBIN" -m compileall -q -f -o2 --invalidation-mode unchecked-hash "$SITE" || true

# Relocate opt-2 bytecode to the legacy sourceless layout, then delete the .py
# we compiled. A .py is removed ONLY after its opt-2 pyc has been moved beside it
# (never orphan an importable module). Non-opt-2 pyc levels and emptied
# __pycache__ dirs are pruned afterward.
echo ">> relocating opt-2 bytecode to sourceless layout + deleting .py sources"
"$PYBIN" - "$SITE" <<'PYEOF'
import os, re, sys
site = sys.argv[1]
# Keep a small allowlist of .py that some libs read as DATA or via stack
# inspection rather than import (rare, but cheap insurance).
KEEP_BASENAMES = set()
# <stem>.cpython-313.opt-2.pyc  ->  capture <stem>
OPT2 = re.compile(r"^(?P<stem>.+)\.cpython-\d+\.opt-2\.pyc$")
moved = removed = kept = 0
for root, dirs, files in os.walk(site):
    if os.path.basename(root) == "__pycache__":
        continue
    pyc_dir = os.path.join(root, "__pycache__")
    # Build stem -> opt-2 pyc path for this dir's __pycache__.
    opt2_by_stem = {}
    if os.path.isdir(pyc_dir):
        for pc in os.listdir(pyc_dir):
            m = OPT2.match(pc)
            if m:
                opt2_by_stem[m.group("stem")] = os.path.join(pyc_dir, pc)
    for f in files:
        if not f.endswith(".py") or f in KEEP_BASENAMES:
            kept += 1
            continue
        stem = f[:-3]
        src = opt2_by_stem.get(stem)
        if src and os.path.exists(src):
            # Move opt-2 pyc to legacy sourceless location: <dir>/<stem>.pyc
            os.replace(src, os.path.join(root, stem + ".pyc"))
            os.remove(os.path.join(root, f))
            moved += 1
            removed += 1
        else:
            kept += 1
print(f">> opt-2 moved={moved}  .py removed={removed}  kept(no opt-2/allowlisted)={kept}")
PYEOF

# Drop every leftover __pycache__ pyc (now redundant) and empty __pycache__ dirs.
find "$SITE" -type d -name '__pycache__' -exec rm -rf {} + 2>/dev/null || true

# --- (4) strip .so to shrink the snapshot — ALIGNMENT-SAFE on aarch64 ---------
# DO NOT use `strip --strip-unneeded` here: on aarch64 it CORRUPTS shared libs
# linked with max-page-size=65536 (numpy's bundled scipy_openblas is the classic
# victim). The dynamic loader then dies at import with:
#   "ELF load command address/offset not page-aligned"
# This is a GNU binutils <2.41 bug (Debian bookworm ships 2.40) and bites on the
# native Graviton build too, not just QEMU. Use elfutils `eu-strip`, which
# preserves PT_LOAD alignment; fall back to `strip --strip-debug`, which only
# drops non-allocatable debug sections and never rewrites loadable-segment
# offsets. The import check in step (4b) is the backstop if a lib still breaks.
if command -v eu-strip >/dev/null 2>&1; then
  echo ">> stripping .so with eu-strip (alignment-safe)"
  strip_so() { eu-strip "$1" 2>/dev/null || true; }
else
  echo ">> eu-strip absent; using 'strip --strip-debug' (alignment-safe fallback)"
  strip_so() { strip --strip-debug "$1" 2>/dev/null || true; }
fi
find "$SITE" -type f -name '*.so*' -print0 | while IFS= read -r -d '' f; do strip_so "$f"; done
# Also strip the standalone CPython's shared libs / extension modules.
find "$VENV" -type f -name '*.so*' ! -path "$SITE/*" -print0 | while IFS= read -r -d '' f; do strip_so "$f"; done

# --- (4c) slim the standalone CPython under base_prefix (/opt/python) ---------
# Steps above only touch the venv site-packages, but the python-build-standalone
# interpreter (full stdlib source + a STATIC libpython*.a + headers + unstripped
# extension .so) is the LARGEST contributor to the base snapshot — `find "$VENV"`
# does not reach it because the venv only SYMLINKS into base_prefix (find does
# not follow symlinks). Remove what a headless exec sandbox never needs and strip
# its shared objects. The import guard (4b) validates the interpreter still works.
PYROOT="$("$PYBIN" -c 'import sys; print(sys.base_prefix)')"
STDLIB_DIR="$("$PYBIN" -c 'import sysconfig; print(sysconfig.get_path("stdlib"))')"
echo ">> slimming standalone CPython: base_prefix=$PYROOT  stdlib=$STDLIB_DIR"
if [ -d "$STDLIB_DIR" ]; then
  BEFORE_PY="$(human "$PYROOT")"
  # Unused stdlib subtrees: no GUI (Agg only), no test suites, no build/pip tooling.
  for sub in test tests idlelib tkinter turtledemo lib2to3 ensurepip __phello__ pydoc_data; do
    rm -rf "${STDLIB_DIR:?}/$sub" 2>/dev/null || true
  done
  # config-*/ holds the static libpython*.a + Makefile (compile-time only).
  find "$STDLIB_DIR" -maxdepth 1 -type d -name 'config-*' -exec rm -rf {} + 2>/dev/null || true
  # Strip stdlib extension modules (lib-dynload .so) — alignment-safe via strip_so.
  find "$STDLIB_DIR" -type f -name '*.so*' -print0 | while IFS= read -r -d '' f; do strip_so "$f"; done
fi
if [ -d "$PYROOT" ]; then
  rm -rf "$PYROOT/include" "$PYROOT/share" 2>/dev/null || true   # C headers + man/docs
  find "$PYROOT" -type f -name '*.a' -delete 2>/dev/null || true  # static libpython*.a (big)
  find "$PYROOT/lib" -maxdepth 1 -type d -name 'pkgconfig' -exec rm -rf {} + 2>/dev/null || true
  # Strip libpython3.x.so and any other shared objects directly under lib/.
  find "$PYROOT/lib" -maxdepth 1 -type f -name '*.so*' -print0 | while IFS= read -r -d '' f; do strip_so "$f"; done
  echo ">> standalone CPython: $BEFORE_PY -> $(human "$PYROOT")"
fi

# --- (4b) VERIFY the shake-down did not break imports (FAIL the build if so) --
# The aggressive prune + sourceless-bytecode conversion can, if wrong, yield an
# image whose heavy stack is unimportable — a defect that would otherwise only
# surface at RUNTIME inside a paid microVM (and is invisible to a Dockerfile that
# never imports). Catch it HERE: import EXACTLY what the fork-server imports for
# this variant and exercise the render path (touches the kept DejaVu Sans font +
# Agg rasterizer too). `set -e` makes any failure abort the image build.
echo ">> verifying imports survive shake-down (variant=$VARIANT)"
case "$VARIANT" in
  base)
    "$PYBIN" -c 'import json, sys, math, base64; print(">> base import check OK")'
    ;;
  mpl)
    "$PYBIN" - <<'PYV'
import io, matplotlib
matplotlib.use("Agg")
import numpy as np
import matplotlib.pyplot as plt
x = np.linspace(0, 6, 64)
plt.plot(x, np.sin(x))
buf = io.BytesIO(); plt.savefig(buf, format="png"); plt.close("all")
assert buf.getbuffer().nbytes > 0, "empty PNG after shake-down"
print(">> mpl import+render check OK")
PYV
    ;;
  sci)
    "$PYBIN" - <<'PYV'
import io, matplotlib
matplotlib.use("Agg")
import numpy as np
import pandas as pd
import seaborn as sns
import matplotlib.pyplot as plt
df = pd.DataFrame({"x": list("abcd"), "y": np.arange(4)})
sns.barplot(data=df, x="x", y="y")
buf = io.BytesIO(); plt.savefig(buf, format="png"); plt.close("all")
assert buf.getbuffer().nbytes > 0, "empty PNG after shake-down"
print(">> sci import+render check OK")
PYV
    ;;
esac

# --- (5) report AFTER -------------------------------------------------------
AFTER_SP="$(human "$SITE")"
AFTER_VENV="$(human "$VENV")"
echo "AFTER   site-packages=$AFTER_SP  venv=$AFTER_VENV"
echo "AFTER   .so=$(count '*.so')  .py=$(count '*.py')  .pyc=$(count '*.pyc')  .a=$(count '*.a')"
echo "SAVINGS site-packages: $BEFORE_SP -> $AFTER_SP   venv: $BEFORE_VENV -> $AFTER_VENV"
echo "============================================================"
echo ">> (record these numbers in images/SIZES.md)"
