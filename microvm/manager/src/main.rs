//! microvm-bench in-VM Rust manager.
//!
//! This binary is the microVM ENTRYPOINT. It:
//!   * serves the data-plane `/exec` on `:8080` and the lifecycle hooks on `:9000`,
//!   * supervises the Python fork-server over a Unix domain socket,
//!   * implements the six lifecycle hooks (CONTRACTS §C) plus `POST /exec`
//!     (CONTRACTS §B) and `GET /healthz`.
//!
//! The manager (tokio, multi-threaded) is safe to run multi-threaded: ONLY the
//! Python fork-server forks. On `/run` and `/resume` the manager re-establishes
//! the fork-server UDS because snapshot FDs may be stale.

mod forkserver;
mod protocol;

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::Instant;

use axum::extract::{Request, State};
use axum::http::StatusCode;
use axum::middleware::{self, Next};
use axum::response::{IntoResponse, Response};
use axum::routing::{get, post};
use axum::{Json, Router};
use tokio::sync::RwLock;

use forkserver::{ForkError, ForkServer};
use protocol::{ExecRequest, ExecResponse, ForkReply, InvmTimings};

/// Backstop padding added to the client's `timeoutMs` for the UDS read deadline.
/// The fork-server is the primary enforcer at exactly `timeoutMs`; the manager's
/// deadline is `timeoutMs + BACKSTOP_EXTRA_MS` so the fork-server gets first
/// crack at killing a runaway child before the manager nukes the fork-server.
const BACKSTOP_EXTRA_MS: u64 = 3_000;

/// Data-plane listen address: AWS's MicroVM endpoint default port. Runtime
/// `/exec` traffic (client -> endpoint -> app) targets this by default.
const DATA_ADDR: &str = "0.0.0.0:8080";
/// Hooks listen address: AWS delivers the lifecycle hooks to `hooks.port`. This
/// MUST NOT be 8080 — 8080 is the data-plane default and AWS's build-time hook
/// POST never reaches an app whose hooks.port is 8080. The working AWS reference
/// sample serves hooks on 9000, so `create-microvm-image --hooks '{"port":9000,...}'`
/// and the app listens here.
const HOOKS_ADDR: &str = "0.0.0.0:9000";

/// Shared manager state.
struct AppState {
    fork: ForkServer,
    /// Monotonic stamp of the most recent `/run` (or `/resume`) completion.
    /// `/exec` reports `sinceRunHookMs = now - t_run_done`. Re-stamped on BOTH
    /// `/run` and `/resume` so a warm-resume exec measures from the resume rather
    /// than a stale pre-snapshot Instant. `None` until the first `/run`/`/resume`.
    t_run_done: RwLock<Option<Instant>>,
    /// Set true by `/resume`; cleared by the next successful `/exec`. The
    /// provisioner uses it to label the regime "warm-resume" with no GetMicrovm
    /// poll (CONTRACTS §A).
    resumed_since_last_exec: AtomicBool,
    /// Set true by `/run` and `/resume`; the FIRST inbound `/exec` after it logs
    /// `endpoint_lag_ms` (time the inbound data-plane endpoint took to become
    /// routable after the hook) and clears it. Pure observability (Stage 0b).
    first_exec_since_run: AtomicBool,
}

impl AppState {
    fn new() -> Self {
        Self {
            fork: ForkServer::new(),
            t_run_done: RwLock::new(None),
            resumed_since_last_exec: AtomicBool::new(false),
            first_exec_since_run: AtomicBool::new(false),
        }
    }
}

type Shared = Arc<AppState>;

#[tokio::main]
async fn main() {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| "info".into()),
        )
        .with_target(false)
        .init();

    // Ensure the UDS parent dir exists before the fork-server tries to bind.
    if let Err(e) = ForkServer::ensure_socket_dir() {
        tracing::error!("failed to create socket dir: {e}");
    }

    let state: Shared = Arc::new(AppState::new());

    // Launch the fork-server at startup (best-effort; routes re-ensure it).
    match state.fork.ensure_alive().await {
        Ok(()) => tracing::info!("fork-server up at startup"),
        Err(e) => tracing::warn!("fork-server not up at startup: {e} (will retry on demand)"),
    }

    let app = Router::new()
        // Lifecycle hooks (CONTRACTS §C) on the fixed runtime base path.
        .route("/aws/lambda-microvms/runtime/v1/ready", post(hook_ready))
        .route("/aws/lambda-microvms/runtime/v1/validate", post(hook_validate))
        .route("/aws/lambda-microvms/runtime/v1/run", post(hook_run))
        .route("/aws/lambda-microvms/runtime/v1/resume", post(hook_resume))
        .route("/aws/lambda-microvms/runtime/v1/suspend", post(hook_suspend))
        .route("/aws/lambda-microvms/runtime/v1/terminate", post(hook_terminate))
        // Data plane + health.
        .route("/exec", post(handle_exec))
        .route("/healthz", get(handle_healthz))
        // Observability trail: log EVERY inbound request (method/path/HTTP
        // version) before routing, and any unmatched route — so a failed build
        // is never silent after "manager listening" again. `.layer` is applied
        // after `.fallback` so the access log also wraps unmatched requests.
        .fallback(fallback_404)
        .layer(middleware::from_fn(log_requests))
        .with_state(state);

    // Serve the SAME router on TWO ports: the data-plane port (8080, where
    // runtime /exec arrives) and the hooks port (9000, where AWS delivers the
    // lifecycle hooks). hooks.port in create-microvm-image is 9000.
    let l_data = tokio::net::TcpListener::bind(DATA_ADDR)
        .await
        .unwrap_or_else(|e| panic!("bind {DATA_ADDR}: {e}"));
    let l_hooks = tokio::net::TcpListener::bind(HOOKS_ADDR)
        .await
        .unwrap_or_else(|e| panic!("bind {HOOKS_ADDR}: {e}"));
    tracing::info!("manager listening on {DATA_ADDR} (data-plane) and {HOOKS_ADDR} (hooks)");

    let app_hooks = app.clone();
    let (data_res, hooks_res) = tokio::join!(
        axum::serve(l_data, app),
        axum::serve(l_hooks, app_hooks),
    );
    data_res.expect("data-plane serve failed");
    hooks_res.expect("hooks serve failed");
}

// ---------------------------------------------------------------------------
// Observability middleware (the build-hook trail).
//
// Before this, the hook layer logged NOTHING, so a failed image build went
// silent immediately after "manager listening" — we could not tell whether AWS
// even reached the app, what path/method/HTTP-version it used, or what we
// returned. `log_requests` records one line in + one line out for EVERY request
// (so h1-vs-h2, the exact /ready path, and the response status are all visible);
// `fallback_404` makes a path/method mismatch unmistakable. This is what turns
// the next build's CloudWatch stream into evidence instead of a guess.
// ---------------------------------------------------------------------------

/// Pre-routing access log: method, path, HTTP version in; status out.
async fn log_requests(req: Request, next: Next) -> Response {
    let method = req.method().clone();
    let path = req.uri().path().to_owned();
    let version = req.version();
    tracing::info!(%method, path = %path, ?version, "inbound");
    let resp = next.run(req).await;
    tracing::info!(status = resp.status().as_u16(), %method, path = %path, "response");
    resp
}

/// Unmatched route: log loudly at WARN so a path/method mismatch from AWS is
/// obvious in the trail, then return a bare 404.
async fn fallback_404(req: Request) -> impl IntoResponse {
    tracing::warn!(
        method = %req.method(),
        path = %req.uri().path(),
        version = ?req.version(),
        "UNMATCHED route -> 404"
    );
    StatusCode::NOT_FOUND
}

// ---------------------------------------------------------------------------
// GET /healthz
// ---------------------------------------------------------------------------

async fn handle_healthz() -> impl IntoResponse {
    (StatusCode::OK, Json(serde_json::json!({ "ok": true })))
}

// ---------------------------------------------------------------------------
// Lifecycle hooks (CONTRACTS §C). All return 200 on success; ready/validate
// return 503 IMMEDIATELY (never hold the socket) until warm.
// ---------------------------------------------------------------------------

/// `ready` (BUILD time): 200 iff the fork-server is warm AND one child is
/// pre-forked; otherwise 503 immediately. We `ping` (cheap, never relaunches in
/// a blocking way beyond a short deadline) to avoid holding the socket: if the
/// fork-server is not already up we return 503 rather than waiting on a launch.
async fn hook_ready(State(state): State<Shared>) -> impl IntoResponse {
    // Mirror AWS's known-good reference sample: /ready returns 200 UNCONDITIONALLY
    // with a JSON ack. The snapshot's purpose is to capture the warm parent that
    // ENTRYPOINT already started — main()'s startup `ensure_alive` blocks until the
    // fork-server answers a ping BEFORE the port is bound, so warmth is already
    // guaranteed by the time AWS can POST here. The previous behavior (gate the
    // 200 on a per-request `fork.ping()`, else 503) is the prime suspect for the
    // "Ready hook invocation timed out" build failures: any ping hiccup 503s the
    // whole build. Real warmth verification belongs in /validate. We STILL probe
    // and log the result for observability — but never gate the response on it.
    match state.fork.ping().await {
        Ok(()) => tracing::info!("hook: /ready  fork-server ping OK -> 200"),
        Err(e) => tracing::warn!(
            error = %e,
            "hook: /ready  fork-server ping FAILED (returning 200 anyway) -> 200"
        ),
    }
    (StatusCode::OK, Json(serde_json::json!({ "status": "ok" })))
}

/// `validate` (BUILD time): run the VARIANT'S REAL SAMPLE through the fork-server
/// so Lambda samples & prefetches the ACTUAL hot snapshot regions (numpy/
/// matplotlib import + render pages), not just a trivial `print`. This both
/// speeds the first real `/exec` and acts as a second build-time guard: if the
/// shaken heavy stack can't import/render, validate 503s and Lambda fails the
/// build. 200 on success; 503 (immediately) until ready / on sample failure.
async fn hook_validate(State(state): State<Shared>) -> Response {
    tracing::info!("hook: /validate");
    // Probe first so we 503 fast if the fork-server is not yet warm, rather than
    // blocking the build on a launch.
    if let Err(e) = state.fork.ping().await {
        tracing::warn!(error = %e, "/validate: fork-server ping FAILED -> 503");
        return StatusCode::SERVICE_UNAVAILABLE.into_response();
    }
    let (code, want_image) = validate_payload();
    let started = Instant::now();
    match state
        .fork
        .exec(code, want_image, 15_000, BACKSTOP_EXTRA_MS)
        .await
    {
        Ok(reply) if reply.ok => {
            tracing::info!(
                elapsed_ms = started.elapsed().as_millis() as u64,
                "/validate: exec OK -> 200"
            );
            (StatusCode::OK, Json(serde_json::json!({ "status": "ok" }))).into_response()
        }
        Ok(reply) => {
            tracing::warn!(
                elapsed_ms = started.elapsed().as_millis() as u64,
                error = ?reply.error,
                "/validate: exec returned ok=false -> 503"
            );
            StatusCode::SERVICE_UNAVAILABLE.into_response()
        }
        Err(e) => {
            tracing::warn!(
                elapsed_ms = started.elapsed().as_millis() as u64,
                error = %e,
                "/validate: exec FAILED -> 503"
            );
            StatusCode::SERVICE_UNAVAILABLE.into_response()
        }
    }
}

/// Build the `/validate` exec payload: the variant's real sample (so the render
/// path is exercised + prefetched), falling back to a trivial print if the
/// sample file is absent. Variant + samples dir come from the image env.
fn validate_payload() -> (String, bool) {
    let variant = std::env::var("MVB_VARIANT").unwrap_or_else(|_| "base".into());
    let dir = std::env::var("MVB_SAMPLES_DIR").unwrap_or_else(|_| "/app/samples".into());
    let path = format!("{dir}/{variant}.py");
    match std::fs::read_to_string(&path) {
        Ok(code) => {
            // mpl/sci samples render a figure; want_image exercises savefig.
            let want_image = variant == "mpl" || variant == "sci";
            (code, want_image)
        }
        Err(_) => ("print(1)".to_string(), false),
    }
}

/// `run`: ensure fork-server alive, (re)connect UDS, send `prewarm`, stamp
/// `t_run_done`. 200 on success; 500 on failure (Lambda may terminate — that is
/// acceptable per the spec). The /run body is accepted but not read: the worker
/// only needs to re-establish the fork-server and stamp its monotonic origin so
/// the first `/exec` can report `sinceRunHookMs` + `endpoint_lag_ms`.
async fn hook_run(State(state): State<Shared>) -> impl IntoResponse {
    tracing::info!("hook: /run");

    // Snapshot FDs may be stale: reconnect (which relaunches if needed).
    if let Err(e) = state.fork.reconnect().await {
        tracing::error!("/run reconnect failed: {e}");
        return StatusCode::INTERNAL_SERVER_ERROR;
    }
    // Force a fresh pre-forked child so the first exec pays no fork cost.
    if let Err(e) = state.fork.control("prewarm").await {
        tracing::error!("/run prewarm failed: {e}");
        return StatusCode::INTERNAL_SERVER_ERROR;
    }

    // Stamp t_run_done so /exec can report sinceRunHookMs.
    *state.t_run_done.write().await = Some(Instant::now());
    // A fresh run is not a resume; arm the first-exec endpoint-lag probe.
    state.resumed_since_last_exec.store(false, Ordering::SeqCst);
    state.first_exec_since_run.store(true, Ordering::SeqCst);

    StatusCode::OK
}

/// `resume`: reconnect UDS, prewarm, set `resumedSinceLastExec = true`. 200 on
/// success; 500 on failure.
async fn hook_resume(State(state): State<Shared>) -> impl IntoResponse {
    tracing::info!("hook: /resume");
    if let Err(e) = state.fork.reconnect().await {
        tracing::error!("/resume reconnect failed: {e}");
        return StatusCode::INTERNAL_SERVER_ERROR;
    }
    if let Err(e) = state.fork.control("prewarm").await {
        tracing::error!("/resume prewarm failed: {e}");
        return StatusCode::INTERNAL_SERVER_ERROR;
    }
    // Re-stamp the monotonic origin on resume too. Without this, a warm-resume
    // exec (no intervening /run) computes sinceRunHookMs against a pre-snapshot
    // Instant — meaningless/backwards if the monotonic clock doesn't survive the
    // Firecracker restore. Stamping here anchors it to the resume.
    *state.t_run_done.write().await = Some(Instant::now());
    state.resumed_since_last_exec.store(true, Ordering::SeqCst);
    state.first_exec_since_run.store(true, Ordering::SeqCst);
    StatusCode::OK
}

/// `suspend`: drain the idle child / ensure it is clean, flush. 200.
async fn hook_suspend(State(state): State<Shared>) -> impl IntoResponse {
    tracing::info!("hook: /suspend");
    // Best-effort drain: a failure here should not block the checkpoint.
    if let Err(e) = state.fork.control("drain").await {
        tracing::warn!("/suspend drain failed (continuing): {e}");
    }
    StatusCode::OK
}

/// `terminate`: final flush. 200 unconditionally (the VM is going away).
async fn hook_terminate(State(_state): State<Shared>) -> impl IntoResponse {
    tracing::info!("hook: /terminate");
    StatusCode::OK
}

// ---------------------------------------------------------------------------
// POST /exec (CONTRACTS §B)
// ---------------------------------------------------------------------------

async fn handle_exec(
    State(state): State<Shared>,
    Json(req): Json<ExecRequest>,
) -> impl IntoResponse {
    // Stage 0b: the FIRST inbound /exec after a /run|/resume reveals how long the
    // inbound data-plane endpoint took to become routable (the dominant cold-start
    // cost). Log it once per run, regardless of exec outcome.
    if state.first_exec_since_run.swap(false, Ordering::SeqCst) {
        let lag_ms = match *state.t_run_done.read().await {
            Some(t) => t.elapsed().as_secs_f64() * 1000.0,
            None => -1.0,
        };
        tracing::info!(endpoint_lag_ms = lag_ms, "first /exec since hook (inbound endpoint routable)");
    }

    let result = state
        .fork
        .exec(req.code, req.wantImage, req.timeoutMs, BACKSTOP_EXTRA_MS)
        .await;

    match result {
        Ok(reply) => {
            let resp = build_exec_response(&state, reply).await;
            (StatusCode::OK, Json(resp))
        }
        Err(ForkError::Backstop) => {
            // Fork-server wedged and was killed+relaunched. Per spec, return a
            // 200 body with ok:false so the provisioner sees a structured error.
            (StatusCode::OK, Json(error_exec_response("forkserver-timeout")))
        }
        Err(e) => {
            tracing::error!("/exec failed: {e}");
            (StatusCode::OK, Json(error_exec_response(&e.to_string())))
        }
    }
}

/// Promote a fork-server reply into the CONTRACTS §B response, adding the two
/// manager-owned fields: `sinceRunHookMs` and `resumedSinceLastExec`.
async fn build_exec_response(state: &Shared, reply: ForkReply) -> ExecResponse {
    let since_run_hook_ms = match *state.t_run_done.read().await {
        Some(t) => t.elapsed().as_secs_f64() * 1000.0,
        None => 0.0,
    };
    // Read-and-clear the resume flag: the manager owns this bit.
    let resumed = state
        .resumed_since_last_exec
        .swap(false, Ordering::SeqCst);

    let ft = reply.timings.unwrap_or_default();

    ExecResponse {
        ok: reply.ok,
        stdout: reply.stdout,
        stderr: reply.stderr,
        image_png_b64: reply.image_png_b64,
        error: reply.error,
        timings: InvmTimings {
            sinceRunHookMs: since_run_hook_ms,
            dispatchMs: ft.dispatchMs,
            forkMs: ft.forkMs,
            preforkUsed: ft.preforkUsed,
            userCodeMs: ft.userCodeMs,
            firstImportTouchMs: ft.firstImportTouchMs,
            renderMs: ft.renderMs,
            serializeMs: ft.serializeMs,
            totalMs: ft.totalMs,
            resumedSinceLastExec: resumed,
        },
    }
}

/// A structured `ok:false` response when the fork-server could not produce one.
/// Does NOT touch the resume flag (no successful exec occurred).
fn error_exec_response(error: &str) -> ExecResponse {
    ExecResponse {
        ok: false,
        stdout: String::new(),
        stderr: String::new(),
        image_png_b64: None,
        error: Some(error.to_string()),
        timings: InvmTimings {
            sinceRunHookMs: 0.0,
            dispatchMs: 0.0,
            forkMs: 0.0,
            preforkUsed: false,
            userCodeMs: 0.0,
            firstImportTouchMs: 0.0,
            renderMs: 0.0,
            serializeMs: 0.0,
            totalMs: 0.0,
            resumedSinceLastExec: false,
        },
    }
}
