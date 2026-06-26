#!/usr/bin/env python3
"""Smoke test / verify gate for forkserver.py (MVB_VARIANT=base, no heavy deps).

Starts forkserver.py as a subprocess, connects to the UDS, and exercises:
  1. op:"exec" running `print(4)` -> stdout contains "4", ok==true, preforkUsed==true
  2. a SECOND exec to confirm the replacement pre-forked child works
  3. op:"ping" sanity check

Exits 0 on success, non-zero on failure.
"""

from __future__ import annotations

import json
import os
import signal
import socket
import struct
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
FORKSERVER = os.path.join(HERE, "forkserver.py")
# Use a writable per-run socket path for local testing (/run is root-owned). The
# forkserver default remains the frozen /run/microvm-bench/forkserver.sock.
SOCKET_PATH = os.path.join(
    os.environ.get("TMPDIR", "/tmp"), f"mvb-forkserver-{os.getpid()}.sock"
)


def send_msg(conn: socket.socket, obj: dict) -> None:
    payload = json.dumps(obj).encode("utf-8")
    conn.sendall(struct.pack(">I", len(payload)) + payload)


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


def request(obj: dict, timeout: float = 30.0) -> dict:
    """Open a fresh UDS connection, send one request, read one response."""
    conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    conn.settimeout(timeout)
    conn.connect(SOCKET_PATH)
    try:
        send_msg(conn, obj)
        return recv_msg(conn)
    finally:
        conn.close()


def wait_for_socket(proc: subprocess.Popen, timeout: float = 30.0) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if proc.poll() is not None:
            raise RuntimeError(
                f"forkserver exited early rc={proc.returncode}"
            )
        if os.path.exists(SOCKET_PATH):
            # Confirm it actually answers.
            try:
                resp = request({"op": "ping"}, timeout=5.0)
                if resp.get("ok") is True:
                    return
            except (OSError, ConnectionError):
                pass
        time.sleep(0.05)
    raise RuntimeError("timed out waiting for forkserver socket")


def main() -> int:
    env = dict(os.environ)
    env["MVB_VARIANT"] = "base"
    env["MVB_SOCKET_PATH"] = SOCKET_PATH

    proc = subprocess.Popen(
        [sys.executable, FORKSERVER],
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )

    try:
        wait_for_socket(proc)

        # 1. First exec — must use the pre-forked child (no fork latency).
        r1 = request({"op": "exec", "code": "print(4)", "wantImage": False, "timeoutMs": 10000})
        assert r1.get("ok") is True, f"exec#1 not ok: {r1}"
        assert "4" in r1.get("stdout", ""), f"exec#1 stdout missing '4': {r1}"
        assert r1["timings"]["preforkUsed"] is True, f"exec#1 not prefork: {r1}"
        assert r1["imagePngB64"] is None, f"exec#1 unexpected image: {r1}"

        # 2. Second exec — confirms the replacement child works.
        r2 = request({"op": "exec", "code": "print(2 + 5)", "wantImage": False, "timeoutMs": 10000})
        assert r2.get("ok") is True, f"exec#2 not ok: {r2}"
        assert "7" in r2.get("stdout", ""), f"exec#2 stdout missing '7': {r2}"
        assert r2["timings"]["preforkUsed"] is True, f"exec#2 not prefork: {r2}"

        # 3. ping sanity.
        rp = request({"op": "ping"})
        assert rp.get("ok") is True, f"ping not ok: {rp}"

        # 4. A failing exec returns ok:false with a traceback, server survives.
        r3 = request({"op": "exec", "code": "raise ValueError('boom')", "wantImage": False, "timeoutMs": 10000})
        assert r3.get("ok") is False, f"exec#3 should fail: {r3}"
        assert "ValueError" in (r3.get("error") or ""), f"exec#3 error missing: {r3}"

        # 5. Server still alive after an error.
        r4 = request({"op": "exec", "code": "print(99)", "wantImage": False, "timeoutMs": 10000})
        assert r4.get("ok") is True and "99" in r4.get("stdout", ""), f"exec#5: {r4}"

        # 6. drain (CONTRACTS §I) — kills the idle child; server survives and a
        #    subsequent exec re-forks on demand (preforkUsed=false), then re-arms.
        rd = request({"op": "drain"})
        assert rd.get("ok") is True, f"drain not ok: {rd}"
        r6 = request({"op": "exec", "code": "print(123)", "wantImage": False, "timeoutMs": 10000})
        assert r6.get("ok") is True and "123" in r6.get("stdout", ""), f"exec after drain: {r6}"
        assert r6["timings"]["preforkUsed"] is False, f"exec after drain should re-fork: {r6}"

        # 7. ENTROPY: two execs must NOT emit the same "random" sequence. The warm
        #    parent's RNG state is snapshot/COW-shared across every forked child, so
        #    without the post-fork _reseed_entropy() call these would be identical.
        #    stdlib `random` (CPython auto-reseeds on fork — belt-and-suspenders):
        rc = "import random; print(random.random())"
        e1 = request({"op": "exec", "code": rc, "wantImage": False, "timeoutMs": 10000})
        e2 = request({"op": "exec", "code": rc, "wantImage": False, "timeoutMs": 10000})
        assert e1.get("ok") and e2.get("ok"), f"entropy exec failed: {e1} {e2}"
        assert e1["stdout"] != e2["stdout"], f"random.random() identical across execs (reseed broken): {e1['stdout']!r}"

        #    numpy LEGACY global (the real snapshot-freeze hazard; NOT auto-reseeded
        #    on fork). Only asserted when numpy is present (mpl/sci variants).
        nc = (
            "import sys\n"
            "try:\n"
            "    import numpy as np\n"
            "    print(np.random.rand())\n"
            "except Exception:\n"
            "    print('NONUMPY')\n"
        )
        n1 = request({"op": "exec", "code": nc, "wantImage": False, "timeoutMs": 15000})
        n2 = request({"op": "exec", "code": nc, "wantImage": False, "timeoutMs": 15000})
        o1, o2 = n1.get("stdout", "").strip(), n2.get("stdout", "").strip()
        if o1 != "NONUMPY" and o2 != "NONUMPY":
            assert o1 != o2, f"np.random.rand() identical across execs (numpy reseed broken): {o1!r}"
            print(f">> entropy check (numpy): differ OK  ({o1} != {o2})")
        else:
            print(">> entropy check (numpy): skipped (numpy not in this variant)")

        print("SMOKE OK")
        return 0
    except Exception as exc:  # noqa: BLE001
        out, err = b"", b""
        try:
            out, err = proc.communicate(timeout=2)
        except Exception:  # noqa: BLE001
            pass
        print(f"SMOKE FAIL: {exc}", file=sys.stderr)
        if out:
            print(f"--- forkserver stdout ---\n{out.decode(errors='replace')}", file=sys.stderr)
        if err:
            print(f"--- forkserver stderr ---\n{err.decode(errors='replace')}", file=sys.stderr)
        return 1
    finally:
        if proc.poll() is None:
            proc.send_signal(signal.SIGTERM)
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait(timeout=5)


if __name__ == "__main__":
    sys.exit(main())
