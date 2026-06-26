//! Fork-server supervision + UDS client.
//!
//! The manager launches the Python fork-server as a child process and talks to
//! it over a Unix domain socket using the FROZEN framing from CONTRACTS §I:
//! a 4-byte big-endian unsigned length prefix followed by that many bytes of
//! UTF-8 JSON, in BOTH directions.
//!
//! Responsibilities:
//!   * launch / relaunch the `python3 $FORKSERVER_PY` child (bounded restart),
//!   * detect a dead fork-server and bring it back,
//!   * (re)connect the UDS on `/run` and `/resume` (snapshot FDs may be stale),
//!   * forward `exec` with a BACKSTOP deadline; on backstop timeout, kill +
//!     relaunch the fork-server so we never leave a wedged process.
//!
//! The fork-server is the PRIMARY exec-timeout enforcer. The manager only
//! supervises and applies a longer backstop.

use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::time::Duration;

use serde::de::DeserializeOwned;
use serde::Serialize;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::UnixStream;
use tokio::process::{Child, Command};
use tokio::sync::Mutex;
use tokio::time::{sleep, timeout};

use crate::protocol::{ForkReply, ForkRequest};

/// FROZEN socket path (CONTRACTS §I). Manager creates the parent dir; the
/// fork-server binds the socket; the manager connects per exec.
///
/// `MVB_SOCKET_PATH` overrides this ONLY for local testing where `/run` is
/// root-owned — it mirrors the identical override the fork-server honors, so the
/// two ends always agree on the path. Production always uses the frozen default.
pub fn socket_path() -> String {
    std::env::var("MVB_SOCKET_PATH")
        .unwrap_or_else(|_| "/run/microvm-bench/forkserver.sock".to_string())
}

/// Default fork-server entrypoint if `$FORKSERVER_PY` is unset.
const DEFAULT_FORKSERVER_PY: &str = "/app/forkserver/forkserver.py";

/// Max consecutive relaunches before we stop trying (bounded restart). Reset on
/// a successful op. Prevents a crash-loop from burning the whole microVM budget.
const MAX_RESTARTS: u32 = 8;

/// How long to wait for the freshly-launched fork-server to bind the socket and
/// answer a `ping` before declaring the launch a failure.
const LAUNCH_READY_TIMEOUT: Duration = Duration::from_secs(20);

/// Poll interval while waiting for the socket to appear / accept connections.
const CONNECT_POLL: Duration = Duration::from_millis(50);

/// Errors surfaced to the HTTP layer. The route handlers decide the status code.
#[derive(Debug)]
pub enum ForkError {
    /// The backstop deadline elapsed waiting on the fork-server for an exec.
    /// The fork-server has been killed + relaunched by the time this is seen.
    Backstop,
    /// Could not (re)launch or reach the fork-server.
    Unavailable(String),
    /// I/O or protocol error talking to the fork-server.
    Io(String),
}

impl std::fmt::Display for ForkError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            ForkError::Backstop => write!(f, "forkserver-timeout"),
            ForkError::Unavailable(m) => write!(f, "forkserver-unavailable: {m}"),
            ForkError::Io(m) => write!(f, "forkserver-io: {m}"),
        }
    }
}

impl std::error::Error for ForkError {}

/// Owns the fork-server child process and serializes access to it.
///
/// One exec runs at a time per microVM, so a single `Mutex` around
/// the child handle is both correct and cheap. UDS connections are short-lived:
/// one connection per op (CONTRACTS §I permits this for simplicity).
pub struct ForkServer {
    forkserver_py: PathBuf,
    inner: Mutex<Inner>,
}

struct Inner {
    child: Option<Child>,
    /// Consecutive failed-launch counter (bounded restart).
    restart_count: u32,
}

impl ForkServer {
    pub fn new() -> Self {
        let forkserver_py = std::env::var("FORKSERVER_PY")
            .unwrap_or_else(|_| DEFAULT_FORKSERVER_PY.to_string())
            .into();
        Self {
            forkserver_py,
            inner: Mutex::new(Inner {
                child: None,
                restart_count: 0,
            }),
        }
    }

    /// Ensure the parent directory of the UDS exists. The fork-server binds the
    /// socket; we just guarantee the directory it lives in.
    pub fn ensure_socket_dir() -> std::io::Result<()> {
        if let Some(parent) = Path::new(&socket_path()).parent() {
            std::fs::create_dir_all(parent)?;
        }
        Ok(())
    }

    /// Launch the fork-server child if it is not already running, then block
    /// until it answers a `ping` (or the launch times out). Idempotent: if the
    /// child is alive and reachable this is a cheap `ping`.
    pub async fn ensure_alive(&self) -> Result<(), ForkError> {
        let mut guard = self.inner.lock().await;
        self.ensure_alive_locked(&mut guard).await
    }

    /// (Re)connect the UDS after a snapshot restore. The connection itself is
    /// per-op, so "reconnect" means: confirm the child is alive and that a fresh
    /// connection + `ping` succeeds. Used by `/run` and `/resume` where snapshot
    /// FDs may be stale.
    pub async fn reconnect(&self) -> Result<(), ForkError> {
        // Force a fresh connection + ping. If the child wedged across a
        // snapshot, ensure_alive_locked's ping will fail and trigger a relaunch.
        let mut guard = self.inner.lock().await;
        self.ensure_alive_locked(&mut guard).await
    }

    async fn ensure_alive_locked(&self, guard: &mut Inner) -> Result<(), ForkError> {
        // If we believe the child is up, verify with a quick ping over a fresh
        // connection. If that fails, fall through to relaunch.
        if Self::child_running(guard) {
            if Self::ping_once().await.is_ok() {
                guard.restart_count = 0;
                return Ok(());
            }
            // Child handle is alive but the socket is unresponsive: kill it.
            Self::kill_child(guard).await;
        } else {
            // Reap any exited handle so the kernel doesn't keep a zombie.
            Self::reap_child(guard).await;
        }

        self.launch_locked(guard).await
    }

    /// Returns true if we hold a child handle that has not yet exited.
    fn child_running(guard: &mut Inner) -> bool {
        match guard.child.as_mut() {
            Some(c) => matches!(c.try_wait(), Ok(None)),
            None => false,
        }
    }

    /// Launch the child and wait for it to answer a ping. Bounded by MAX_RESTARTS.
    async fn launch_locked(&self, guard: &mut Inner) -> Result<(), ForkError> {
        if guard.restart_count >= MAX_RESTARTS {
            return Err(ForkError::Unavailable(format!(
                "exceeded {MAX_RESTARTS} restarts"
            )));
        }
        guard.restart_count += 1;

        // Remove a stale socket so the fork-server can bind cleanly.
        let _ = std::fs::remove_file(socket_path());

        tracing::info!(
            forkserver_py = %self.forkserver_py.display(),
            attempt = guard.restart_count,
            "launching fork-server"
        );

        // Inherit env (MVB_VARIANT, BLAS thread-pinning vars, etc.) and stdio so
        // Python stdout/stderr flow to CloudWatch via the execution role.
        let child = Command::new("python3")
            .arg(&self.forkserver_py)
            .stdin(Stdio::null())
            .stdout(Stdio::inherit())
            .stderr(Stdio::inherit())
            // Put the fork-server in its OWN process group so the backstop can
            // signal the group; the descendant sweep in kill_child handles
            // user-code grandchildren that re-group via setpgrp.
            .process_group(0)
            .kill_on_drop(true)
            .spawn()
            .map_err(|e| ForkError::Unavailable(format!("spawn python3: {e}")))?;

        guard.child = Some(child);

        // Wait for the socket to accept a connection AND answer a ping.
        let ready = timeout(LAUNCH_READY_TIMEOUT, async {
            loop {
                // If the child died during startup, stop waiting immediately.
                if !Self::child_running(guard) {
                    return Err(ForkError::Unavailable(
                        "fork-server exited during launch".into(),
                    ));
                }
                if Self::ping_once().await.is_ok() {
                    return Ok(());
                }
                sleep(CONNECT_POLL).await;
            }
        })
        .await;

        match ready {
            Ok(Ok(())) => {
                guard.restart_count = 0;
                tracing::info!("fork-server ready");
                Ok(())
            }
            Ok(Err(e)) => {
                Self::kill_child(guard).await;
                Err(e)
            }
            Err(_) => {
                Self::kill_child(guard).await;
                Err(ForkError::Unavailable("fork-server launch timed out".into()))
            }
        }
    }

    /// Open a fresh UDS connection and round-trip a single framed request.
    async fn roundtrip_once<T: DeserializeOwned>(
        req: &ForkRequest,
        read_deadline: Duration,
    ) -> Result<T, ForkError> {
        let mut stream = UnixStream::connect(socket_path())
            .await
            .map_err(|e| ForkError::Io(format!("connect: {e}")))?;

        write_frame(&mut stream, req)
            .await
            .map_err(|e| ForkError::Io(format!("write: {e}")))?;

        match timeout(read_deadline, read_frame::<T>(&mut stream)).await {
            Ok(Ok(reply)) => Ok(reply),
            Ok(Err(e)) => Err(ForkError::Io(format!("read: {e}"))),
            Err(_) => Err(ForkError::Backstop),
        }
    }

    /// Single ping over a fresh connection with a short deadline.
    async fn ping_once() -> Result<(), ForkError> {
        let req = ForkRequest::op_only("ping");
        let reply: ForkReply =
            Self::roundtrip_once(&req, Duration::from_secs(2)).await?;
        if reply.ok {
            Ok(())
        } else {
            Err(ForkError::Io("ping returned ok=false".into()))
        }
    }

    /// Public ping used by `/ready`: succeeds only if the fork-server is warm.
    pub async fn ping(&self) -> Result<(), ForkError> {
        Self::ping_once().await
    }

    /// Send a control op (`prewarm` | `drain`) over a fresh connection, ensuring
    /// the fork-server is alive first.
    pub async fn control(&self, op: &'static str) -> Result<ForkReply, ForkError> {
        self.ensure_alive().await?;
        let req = ForkRequest::op_only(op);
        Self::roundtrip_once(&req, Duration::from_secs(30)).await
    }

    /// Forward an `exec` to the fork-server with a BACKSTOP deadline of
    /// `timeout_ms + backstop_extra_ms`. The fork-server enforces the real
    /// `timeoutMs`; if it itself wedges past the backstop, we kill + relaunch it
    /// and surface `ForkError::Backstop` so the caller returns
    /// `{ok:false,error:"forkserver-timeout"}`.
    pub async fn exec(
        &self,
        code: String,
        want_image: bool,
        timeout_ms: u64,
        backstop_extra_ms: u64,
    ) -> Result<ForkReply, ForkError> {
        // Cheap liveness only: ensure the fork-server PROCESS exists. We do NOT
        // pay a full UDS connect+ping round-trip on every exec (that was
        // unmeasured "dark" latency on the hot path, attributed to no timing
        // field). A wedged-but-alive fork-server is caught by the backstop below
        // and relaunched; a process that has actually exited is relaunched here.
        {
            let mut guard = self.inner.lock().await;
            if !Self::child_running(&mut guard) {
                Self::reap_child(&mut guard).await;
                self.launch_locked(&mut guard).await?;
            }
        }

        let backstop = Duration::from_millis(timeout_ms.saturating_add(backstop_extra_ms));
        let req = ForkRequest::exec(code, want_image, timeout_ms);

        let result = Self::roundtrip_once::<ForkReply>(&req, backstop).await;

        if matches!(result, Err(ForkError::Backstop)) {
            tracing::warn!("fork-server backstop deadline hit; killing + relaunching");
            // The fork-server wedged: tear it down so the next request is clean.
            let mut guard = self.inner.lock().await;
            Self::kill_child(guard.as_mut_for_kill()).await;
            // Best-effort relaunch so a subsequent request finds it warm; ignore
            // launch errors here (the caller already gets Backstop).
            let _ = self.launch_locked(&mut guard).await;
        }

        result
    }

    /// SIGKILL the fork-server AND its entire descendant tree, then reap. The
    /// fork-server's user-code children call `setpgrp()` (so a single killpg on
    /// the fork-server's group does NOT reach them); we therefore enumerate the
    /// descendant tree from /proc BEFORE tearing the parent down (after which
    /// orphans reparent to us, PID 1) and SIGKILL every pid, so nothing is left
    /// wedged. Then we reap any reparented zombies.
    async fn kill_child(guard: &mut Inner) {
        if let Some(mut child) = guard.child.take() {
            if let Some(pid) = child.id() {
                let root = pid as i32;
                // Snapshot the whole subtree while the parent links still exist.
                let mut victims = collect_descendants(root);
                victims.push(root);
                // Group kill first (cheap; catches anything still in the
                // fork-server's group), then every collected pid individually so
                // re-grouped grandchildren cannot escape.
                let _ = nix::sys::signal::kill(
                    nix::unistd::Pid::from_raw(-root),
                    nix::sys::signal::Signal::SIGKILL,
                );
                for v in victims {
                    let _ = nix::sys::signal::kill(
                        nix::unistd::Pid::from_raw(v),
                        nix::sys::signal::Signal::SIGKILL,
                    );
                }
            }
            let _ = child.start_kill();
            let _ = child.wait().await;
            // Reap any grandchildren that reparented to us (PID 1 in the microVM)
            // so they do not linger as zombies.
            reap_orphans();
        }
    }

    /// Reap an already-exited child handle (no signal needed).
    async fn reap_child(guard: &mut Inner) {
        if let Some(mut child) = guard.child.take() {
            let _ = child.start_kill();
            let _ = child.wait().await;
        }
    }
}

impl Inner {
    /// Helper so `kill_child` (which takes `&mut Inner`) can be called while we
    /// already hold the lock guard.
    fn as_mut_for_kill(&mut self) -> &mut Inner {
        self
    }
}

impl Default for ForkServer {
    fn default() -> Self {
        Self::new()
    }
}

// ---------------------------------------------------------------------------
// UDS framing (CONTRACTS §I): 4-byte big-endian length prefix + UTF-8 JSON.
// ---------------------------------------------------------------------------

/// Reject absurd frame sizes so a corrupt length prefix can't OOM us.
const MAX_FRAME_BYTES: usize = 64 * 1024 * 1024;

async fn write_frame<W, T>(w: &mut W, value: &T) -> std::io::Result<()>
where
    W: AsyncWriteExt + Unpin,
    T: Serialize,
{
    let body = serde_json::to_vec(value)
        .map_err(|e| std::io::Error::new(std::io::ErrorKind::InvalidData, e))?;
    let len: u32 = body
        .len()
        .try_into()
        .map_err(|_| std::io::Error::new(std::io::ErrorKind::InvalidData, "frame too large"))?;
    w.write_all(&len.to_be_bytes()).await?;
    w.write_all(&body).await?;
    w.flush().await?;
    Ok(())
}

async fn read_frame<T>(r: &mut (impl AsyncReadExt + Unpin)) -> std::io::Result<T>
where
    T: DeserializeOwned,
{
    let mut len_buf = [0u8; 4];
    r.read_exact(&mut len_buf).await?;
    let len = u32::from_be_bytes(len_buf) as usize;
    if len > MAX_FRAME_BYTES {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            "frame exceeds maximum size",
        ));
    }
    let mut body = vec![0u8; len];
    r.read_exact(&mut body).await?;
    serde_json::from_slice(&body)
        .map_err(|e| std::io::Error::new(std::io::ErrorKind::InvalidData, e))
}

// ---------------------------------------------------------------------------
// Descendant teardown (backstop). The fork-server's user-code children re-group
// via setpgrp(), so we cannot rely on a single process-group kill; instead we
// enumerate the descendant tree from /proc and SIGKILL every pid.
// ---------------------------------------------------------------------------

/// Read PPid from `/proc/<pid>/status` (robust to spaces/newlines in comm,
/// unlike field-splitting `/proc/<pid>/stat`).
fn read_ppid(pid: i32) -> Option<i32> {
    let data = std::fs::read_to_string(format!("/proc/{pid}/status")).ok()?;
    for line in data.lines() {
        if let Some(rest) = line.strip_prefix("PPid:") {
            return rest.trim().parse::<i32>().ok();
        }
    }
    None
}

/// Collect all transitive descendants of `root` (excluding `root`) from /proc.
fn collect_descendants(root: i32) -> Vec<i32> {
    use std::collections::BTreeMap;
    let mut ppid_of: BTreeMap<i32, i32> = BTreeMap::new();
    if let Ok(entries) = std::fs::read_dir("/proc") {
        for e in entries.flatten() {
            if let Ok(pid) = e.file_name().to_string_lossy().parse::<i32>() {
                if let Some(ppid) = read_ppid(pid) {
                    ppid_of.insert(pid, ppid);
                }
            }
        }
    }
    let mut out = Vec::new();
    for &pid in ppid_of.keys() {
        // Walk ancestry; if root appears, pid is a descendant.
        let mut cur = pid;
        for _ in 0..64 {
            match ppid_of.get(&cur) {
                Some(&pp) if pp == root => {
                    out.push(pid);
                    break;
                }
                Some(&pp) if pp > 1 => cur = pp,
                _ => break,
            }
        }
    }
    out
}

/// Best-effort reap of reparented zombie children (the manager is PID 1 in the
/// microVM, so orphaned grandchildren reparent to it).
fn reap_orphans() {
    use nix::sys::wait::{waitpid, WaitPidFlag, WaitStatus};
    use nix::unistd::Pid;
    loop {
        match waitpid(Pid::from_raw(-1), Some(WaitPidFlag::WNOHANG)) {
            Ok(WaitStatus::StillAlive) | Err(_) => break,
            Ok(_) => continue,
        }
    }
}
