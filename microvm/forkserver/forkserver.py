#!/usr/bin/env python3
"""microvm-bench warm Python fork-server.

A strictly SINGLE-THREADED process that imports the heavy libs ONCE (the warm
parent), binds a Unix domain socket, and serves exec requests by handing each
job to a PRE-FORKED idle child so the FIRST exec pays no fork latency.

Protocol (CONTRACTS §I): 4-byte big-endian length prefix + UTF-8 JSON, both
directions, over the UDS at /run/microvm-bench/forkserver.sock.

  op "ping"    -> {"ok": true}
  op "prewarm" -> ensure one idle child exists -> {"ok": true}
  op "drain"   -> kill+reap the idle child so it is NOT captured in a suspend
                  snapshot (manager re-arms via prewarm on resume) -> {"ok": true}
  op "exec" {code, wantImage, timeoutMs} -> CONTRACTS §B-shaped JSON (the
            timings block minus sinceRunHookMs/resumedSinceLastExec, which the
            manager adds).

Safety model: the warm parent stays single-threaded (BLAS pinned to 1 thread,
matplotlib Agg) so fork() is safe in the snapshot. Untrusted user code runs in
a pre-forked child placed in its own process group under rlimits; the parent is
the primary timeout enforcer and SIGKILLs the whole child process group on
timeout, never leaving a wedged or zombie process.
"""

from __future__ import annotations

# --- Single-thread BLAS + headless matplotlib BEFORE importing heavy libs. ---
# These must be set in the environment prior to numpy/matplotlib import so the
# warm parent never spawns BLAS/OpenMP thread pools (fork-unsafe in a snapshot).
import os

os.environ.setdefault("OPENBLAS_NUM_THREADS", "1")
os.environ.setdefault("OMP_NUM_THREADS", "1")
os.environ.setdefault("MKL_NUM_THREADS", "1")
os.environ.setdefault("NUMEXPR_NUM_THREADS", "1")

import base64
import contextlib
import io
import json
import math
import resource
import select
import signal
import socket
import struct
import sys
import time

# FROZEN contract path (CONTRACTS §I). MVB_SOCKET_PATH overrides ONLY for local
# testing where /run is root-owned; production always uses the default.
SOCKET_PATH = os.environ.get("MVB_SOCKET_PATH", "/run/microvm-bench/forkserver.sock")
SOCKET_DIR = os.path.dirname(SOCKET_PATH)

# rlimit defaults
DEFAULT_MEM_LIMIT_MB = 1536  # ~1.5 GB RLIMIT_AS unless MVB_MEM_LIMIT_MB overrides
FSIZE_LIMIT = 32 * 1024 * 1024  # 32 MiB
NOFILE_LIMIT = 256

# Backstop slack added to the child's hard CPU rlimit (seconds).
CPU_RLIMIT_SLACK = 1

# Parent waits this many ms beyond the request timeout before declaring the
# child wedged and killing it (covers result-pipe drain after user code ends).
PARENT_TIMEOUT_SLACK_MS = 250


# --------------------------------------------------------------------------- #
# Warm import of the heavy stack, gated on MVB_VARIANT.
# --------------------------------------------------------------------------- #
def _build_globals() -> dict:
    """Import the variant's stack ONCE and return the base globals for user code.

    base -> stdlib only
    mpl  -> numpy + matplotlib.pyplot   (np, plt)
    sci  -> numpy + pandas + matplotlib.pyplot + seaborn  (np, pd, plt, sns)
    """
    variant = os.environ.get("MVB_VARIANT", "base").strip().lower()
    g: dict = {"__name__": "__main__", "__builtins__": __builtins__}

    if variant in ("mpl", "sci"):
        import matplotlib

        matplotlib.use("Agg")  # headless, no GUI thread
        import matplotlib.pyplot as plt
        import numpy as np

        g["np"] = np
        g["plt"] = plt

    if variant == "sci":
        import pandas as pd
        import seaborn as sns

        g["pd"] = pd
        g["sns"] = sns

    return g


VARIANT = os.environ.get("MVB_VARIANT", "base").strip().lower()
BASE_GLOBALS = _build_globals()

# matplotlib.pyplot handle for figure capture (None for base variant).
_PLT = BASE_GLOBALS.get("plt")


# --------------------------------------------------------------------------- #
# Length-prefixed JSON framing (CONTRACTS §I).
# --------------------------------------------------------------------------- #
def _recv_exact(conn: socket.socket, n: int) -> bytes:
    buf = bytearray()
    while len(buf) < n:
        chunk = conn.recv(n - len(buf))
        if not chunk:
            raise ConnectionError("peer closed during framed read")
        buf.extend(chunk)
    return bytes(buf)


def recv_msg(conn: socket.socket) -> dict:
    (length,) = struct.unpack(">I", _recv_exact(conn, 4))
    return json.loads(_recv_exact(conn, length).decode("utf-8"))


def send_msg(conn: socket.socket, obj: dict) -> None:
    payload = json.dumps(obj).encode("utf-8")
    conn.sendall(struct.pack(">I", len(payload)) + payload)


def _read_pipe_exact(fd: int, n: int) -> bytes:
    buf = bytearray()
    while len(buf) < n:
        chunk = os.read(fd, n - len(buf))
        if not chunk:
            raise ConnectionError("pipe closed during framed read")
        buf.extend(chunk)
    return bytes(buf)


def _read_pipe_msg(fd: int) -> dict:
    (length,) = struct.unpack(">I", _read_pipe_exact(fd, 4))
    return json.loads(_read_pipe_exact(fd, length).decode("utf-8"))


def _write_pipe_msg(fd: int, obj: dict) -> None:
    payload = json.dumps(obj).encode("utf-8")
    os.write(fd, struct.pack(">I", len(payload)))
    # os.write may short-write; loop to flush the body.
    view = memoryview(payload)
    off = 0
    while off < len(view):
        off += os.write(fd, view[off:])


# --------------------------------------------------------------------------- #
# Idle pre-forked child handle.
# --------------------------------------------------------------------------- #
class Child:
    """A pre-forked idle child blocked reading its job pipe.

    job pipe:    parent --(JSON job)--> child
    result pipe: child  --(JSON result)--> parent
    """

    __slots__ = ("pid", "job_w", "res_r", "pgid")

    def __init__(self, pid: int, job_w: int, res_r: int):
        self.pid = pid
        self.job_w = job_w
        self.res_r = res_r
        self.pgid = pid  # child calls setpgrp() -> its pgid == its pid

    def close_fds(self) -> None:
        for fd in (self.job_w, self.res_r):
            with contextlib.suppress(OSError):
                os.close(fd)


def _current_vmsize_bytes() -> int:
    """Best-effort current virtual address-space size (VmSize) of this process.

    Used to size RLIMIT_AS relative to the inherited warm-parent footprint so the
    cap grants headroom to user code rather than counting the resident library
    set against it. Returns 0 if /proc is unavailable (then the cap is just the
    user budget — acceptable on platforms without /proc, e.g. local macOS tests).
    """
    try:
        with open("/proc/self/status", "r") as fh:
            for line in fh:
                if line.startswith("VmSize:"):
                    return int(line.split()[1]) * 1024  # value is in kB
    except (OSError, ValueError, IndexError):
        pass
    return 0


def _set_child_rlimits(timeout_ms: int) -> None:
    """Apply hard sandbox limits BEFORE running untrusted user code."""
    cpu = int(math.ceil(timeout_ms / 1000.0)) + CPU_RLIMIT_SLACK
    resource.setrlimit(resource.RLIMIT_CPU, (cpu, cpu))

    mem_mb = DEFAULT_MEM_LIMIT_MB
    env_mb = os.environ.get("MVB_MEM_LIMIT_MB")
    if env_mb:
        with contextlib.suppress(ValueError):
            mem_mb = int(env_mb)
    # RLIMIT_AS caps VIRTUAL address space, not RSS. The child is COW-forked from
    # a warm parent that has already mapped the heavy stack (numpy/pandas/seaborn/
    # matplotlib + BLAS arenas + 64K-page glibc arenas on aarch64) — its inherited
    # VmSize can be well over a GiB before user code runs. A flat 1.5 GiB cap would
    # therefore brick even trivial user code with a spurious MemoryError (worst on
    # sci). Size the cap as inherited-footprint + the user budget so MVB_MEM_LIMIT_MB
    # is the headroom GRANTED TO USER CODE on top of the resident library set.
    base_bytes = _current_vmsize_bytes()
    mem_bytes = base_bytes + mem_mb * 1024 * 1024
    with contextlib.suppress(ValueError, OSError):
        resource.setrlimit(resource.RLIMIT_AS, (mem_bytes, mem_bytes))

    resource.setrlimit(resource.RLIMIT_FSIZE, (FSIZE_LIMIT, FSIZE_LIMIT))
    resource.setrlimit(resource.RLIMIT_NOFILE, (NOFILE_LIMIT, NOFILE_LIMIT))


def _reseed_entropy() -> None:
    """Reseed stateful PRNGs from LIVE OS entropy — post-fork, before user code.

    SNAPSHOT HAZARD (see the aws-lambda-microvms skill): the warm parent imports the stack ONCE at
    BUILD time, so any RNG state initialized then is captured in the Firecracker
    snapshot and COW-inherited by every microVM AND every forked child. Without
    this reseed, `random.*` and the legacy `numpy.random.*` global would emit
    the SAME "random" sequence on every exec of every microVM.

    `os.urandom` reads /dev/urandom live (post-snapshot), so each child gets
    distinct entropy. Note: `secrets.SystemRandom`, `os.urandom`, `uuid.uuid4`,
    and `numpy.random.default_rng()` already pull from the OS per-call and are
    snapshot-safe; this only needs to fix the stateful module globals. OpenSSL
    RNG is handled by the al2023-minimal snapshot-safe build.
    """
    import random as _random

    _random.seed(os.urandom(16))  # reseeds the `random` module's global instance
    np = BASE_GLOBALS.get("np")
    if np is not None:
        # Legacy global RandomState (np.random.rand/randn/...). default_rng() is
        # already OS-seeded per call, so only the legacy global needs reseeding.
        with contextlib.suppress(Exception):
            np.random.seed(struct.unpack("<I", os.urandom(4))[0])


def _run_user_code(job: dict) -> dict:
    """Execute untrusted user code in THIS (child) process and return §B JSON.

    Called after the child has set its process group and received the job.
    Timings use time.monotonic_ns().
    """
    t_received = job["_t_received_ns"]
    t_start = time.monotonic_ns()
    dispatch_ms = (t_start - t_received) / 1e6

    code = job.get("code", "")
    want_image = bool(job.get("wantImage", False))
    timeout_ms = int(job.get("timeoutMs", 10000))

    _set_child_rlimits(timeout_ms)

    out_buf = io.StringIO()
    err_buf = io.StringIO()
    ok = True
    error = None
    image_b64 = None
    first_import_touch_ms = 0.0
    render_ms = 0.0

    globals_copy = dict(BASE_GLOBALS)
    globals_copy["__name__"] = "__main__"

    # Drop any figures lingering from a prior touch so wantImage is clean.
    if _PLT is not None:
        with contextlib.suppress(Exception):
            _PLT.close("all")

    t_user_start = time.monotonic_ns()
    old_out, old_err = sys.stdout, sys.stderr
    sys.stdout, sys.stderr = out_buf, err_buf
    try:
        compiled = compile(code, "<user>", "exec")
        exec(compiled, globals_copy)  # noqa: S102 -- sandboxed untrusted exec
    except BaseException as exc:  # noqa: BLE001 -- report everything to caller
        ok = False
        import traceback

        error = "".join(traceback.format_exception(exc))
        err_buf.write(error)
    finally:
        sys.stdout, sys.stderr = old_out, old_err
    user_code_ms = (time.monotonic_ns() - t_user_start) / 1e6

    # Capture the current matplotlib figure if requested and one exists.
    if ok and want_image and _PLT is not None and _PLT.get_fignums():
        t_render = time.monotonic_ns()
        try:
            png = io.BytesIO()
            _PLT.savefig(png, format="png", bbox_inches="tight")
            image_b64 = base64.b64encode(png.getvalue()).decode("ascii")
        except Exception as exc:  # noqa: BLE001
            err_buf.write(f"\n[savefig failed] {exc!r}\n")
        finally:
            with contextlib.suppress(Exception):
                _PLT.close("all")
        render_ms = (time.monotonic_ns() - t_render) / 1e6

    t_serialize = time.monotonic_ns()
    result = {
        "ok": ok,
        "stdout": out_buf.getvalue(),
        "stderr": err_buf.getvalue(),
        "imagePngB64": image_b64,
        "error": error,
        "timings": {
            "dispatchMs": dispatch_ms,
            "forkMs": job.get("_fork_ms", 0.0),
            "preforkUsed": job.get("_prefork_used", True),
            "userCodeMs": user_code_ms,
            "firstImportTouchMs": first_import_touch_ms,
            "renderMs": render_ms,
            "serializeMs": 0.0,  # filled in just below
            "totalMs": 0.0,
        },
    }
    # serializeMs measures the json/base64 marshalling cost.
    serialize_ms = (time.monotonic_ns() - t_serialize) / 1e6
    result["timings"]["serializeMs"] = serialize_ms
    result["timings"]["totalMs"] = (time.monotonic_ns() - t_start) / 1e6
    return result


def _child_main(job_r: int, res_w: int) -> None:
    """Entry point for a pre-forked child. Blocks until a job arrives, runs it,
    writes the result back, and exits. NEVER returns to the parent loop."""
    # Own process group so the parent can SIGKILL the whole group on timeout.
    os.setpgrp()

    # Reseed PRNGs from LIVE OS entropy NOW — post-fork, post-snapshot-restore,
    # and (because this child is pre-forked) BEFORE the job ever arrives, so the
    # reseed cost is off the exec critical path entirely. Without this every
    # microVM/fork would inherit the snapshot's frozen numpy/random state and
    # emit identical "random" output (AWS documents this snapshot CSPRNG hazard).
    _reseed_entropy()

    exit_code = 0
    try:
        job = _read_pipe_msg(job_r)
        result = _run_user_code(job)
        _write_pipe_msg(res_w, result)
    except BaseException:  # noqa: BLE001 -- never propagate; just exit
        exit_code = 1
    finally:
        with contextlib.suppress(OSError):
            os.close(job_r)
        with contextlib.suppress(OSError):
            os.close(res_w)
    os._exit(exit_code)


def prefork_child() -> Child:
    """Fork one idle child blocked reading its job pipe; return its handle."""
    job_r, job_w = os.pipe()
    res_r, res_w = os.pipe()
    pid = os.fork()
    if pid == 0:
        # Child: keep only its own ends.
        os.close(job_w)
        os.close(res_r)
        _child_main(job_r, res_w)
        os._exit(0)  # unreachable
    # Parent: keep only its own ends.
    os.close(job_r)
    os.close(res_w)
    return Child(pid, job_w, res_r)


# --------------------------------------------------------------------------- #
# Server.
# --------------------------------------------------------------------------- #
class ForkServer:
    def __init__(self) -> None:
        self.idle: Child | None = None

    def ensure_idle(self) -> None:
        if self.idle is None:
            self.idle = prefork_child()

    def drain_idle(self) -> None:
        """Kill+reap the idle child so a suspend snapshot does not capture a
        pre-forked child (the manager re-arms one via `prewarm` on resume)."""
        if self.idle is not None:
            child = self.idle
            self.idle = None
            self._kill_and_reap(child)

    def _kill_and_reap(self, child: Child) -> None:
        """SIGKILL the child's whole process group and reap it. Idempotent."""
        with contextlib.suppress(ProcessLookupError, OSError):
            os.killpg(child.pgid, signal.SIGKILL)
        with contextlib.suppress(ProcessLookupError, OSError):
            os.kill(child.pid, signal.SIGKILL)
        with contextlib.suppress(ChildProcessError, OSError):
            os.waitpid(child.pid, 0)
        child.close_fds()

    def _reap(self, child: Child) -> None:
        with contextlib.suppress(ChildProcessError, OSError):
            os.waitpid(child.pid, 0)
        child.close_fds()

    def handle_exec(self, req: dict) -> dict:
        timeout_ms = int(req.get("timeoutMs", 10000))

        # Acquire a child: use the pre-forked idle one (forkMs≈0) if present,
        # else fork on demand (preforkUsed=false, forkMs>0).
        if self.idle is not None:
            child = self.idle
            self.idle = None
            prefork_used = True
            fork_ms = 0.0
        else:
            t_fork = time.monotonic_ns()
            child = prefork_child()
            fork_ms = (time.monotonic_ns() - t_fork) / 1e6
            prefork_used = False

        job = {
            "code": req.get("code", ""),
            "wantImage": bool(req.get("wantImage", False)),
            "timeoutMs": timeout_ms,
            "_t_received_ns": time.monotonic_ns(),
            "_fork_ms": fork_ms,
            "_prefork_used": prefork_used,
        }

        timed_out = False
        try:
            _write_pipe_msg(child.job_w, job)
        except OSError:
            # Child died before receiving the job; treat as failure. The
            # replacement idle child is re-armed by serve() AFTER the reply is
            # sent (deferred prefork — off the measured exec round-trip).
            self._kill_and_reap(child)
            return self._error_result("child unavailable", fork_ms, prefork_used)

        # Parent is the PRIMARY timeout enforcer: wait for the result pipe up to
        # timeoutMs (+ a small drain slack); on timeout SIGKILL the group.
        deadline = time.monotonic() + (timeout_ms + PARENT_TIMEOUT_SLACK_MS) / 1000.0
        result: dict | None = None
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                timed_out = True
                break
            rlist, _, _ = select.select([child.res_r], [], [], remaining)
            if not rlist:
                timed_out = True
                break
            try:
                result = _read_pipe_msg(child.res_r)
            except (ConnectionError, OSError, ValueError):
                result = None  # child crashed mid-write
            break

        if timed_out:
            self._kill_and_reap(child)
            return self._timeout_result(fork_ms, prefork_used)

        # Got (or failed to get) a result; reap the now-exiting child. The
        # replacement idle child is pre-forked by serve() AFTER this reply is
        # sent, so the fork() never inflates the manager-measured exec RTT.
        self._reap(child)

        if result is None:
            return self._error_result("child crashed", fork_ms, prefork_used)
        return result

    @staticmethod
    def _empty_timings(fork_ms: float, prefork_used: bool) -> dict:
        return {
            "dispatchMs": 0.0,
            "forkMs": fork_ms,
            "preforkUsed": prefork_used,
            "userCodeMs": 0.0,
            "firstImportTouchMs": 0.0,
            "renderMs": 0.0,
            "serializeMs": 0.0,
            "totalMs": 0.0,
        }

    def _timeout_result(self, fork_ms: float, prefork_used: bool) -> dict:
        return {
            "ok": False,
            "stdout": "",
            "stderr": "",
            "imagePngB64": None,
            "error": "timeout",
            "timings": self._empty_timings(fork_ms, prefork_used),
        }

    def _error_result(self, msg: str, fork_ms: float, prefork_used: bool) -> dict:
        return {
            "ok": False,
            "stdout": "",
            "stderr": "",
            "imagePngB64": None,
            "error": msg,
            "timings": self._empty_timings(fork_ms, prefork_used),
        }

    def handle(self, req: dict) -> dict:
        op = req.get("op")
        if op == "ping":
            return {"ok": True}
        if op == "prewarm":
            self.ensure_idle()
            return {"ok": True}
        if op == "drain":
            self.drain_idle()
            return {"ok": True}
        if op == "exec":
            return self.handle_exec(req)
        return {"ok": False, "error": f"unknown op: {op!r}"}

    def serve(self) -> None:
        os.makedirs(SOCKET_DIR, exist_ok=True)
        with contextlib.suppress(FileNotFoundError):
            os.unlink(SOCKET_PATH)

        srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        srv.bind(SOCKET_PATH)
        srv.listen(64)

        # Pre-fork the first idle child immediately so the FIRST exec pays no
        # fork latency (explicit user requirement).
        self.ensure_idle()

        # SIGCHLD: ignore so any unexpected child death is auto-reaped and never
        # becomes a zombie. We waitpid() explicitly for the children we track,
        # which still works because we only reap our specific pids.
        # (We do NOT use SIG_IGN globally because that breaks waitpid; instead
        # reap explicitly. Default disposition is fine for single-threaded.)

        try:
            while True:
                try:
                    conn, _ = srv.accept()
                except InterruptedError:
                    continue
                req = None
                with conn:
                    try:
                        req = recv_msg(conn)
                    except (ConnectionError, OSError, ValueError):
                        continue
                    try:
                        resp = self.handle(req)
                    except Exception as exc:  # noqa: BLE001
                        resp = {"ok": False, "error": f"server error: {exc!r}"}
                    with contextlib.suppress(OSError):
                        send_msg(conn, resp)
                # Deferred prefork: re-arm the idle child AFTER the exec reply is
                # sent and the connection is closed, so the warm-parent fork()
                # cost is fully OFF the manager-measured exec round-trip. Because
                # the server is single-threaded, this always completes before the
                # next accept(), so the following exec still finds an idle child.
                if isinstance(req, dict) and req.get("op") == "exec":
                    with contextlib.suppress(Exception):
                        self.ensure_idle()
        finally:
            with contextlib.suppress(FileNotFoundError, OSError):
                os.unlink(SOCKET_PATH)


def main() -> None:
    ForkServer().serve()


if __name__ == "__main__":
    main()
