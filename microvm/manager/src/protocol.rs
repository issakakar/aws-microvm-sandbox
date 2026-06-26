//! Wire types. Field names match CONTRACTS §B (Provisioner -> worker) and §I
//! (manager <-> fork-server) BYTE-FOR-BYTE. Do not rename fields.
//!
//! These structs deliberately use camelCase field names (not Rust snake_case)
//! because serde serializes/deserializes by the field identifier and the wire
//! contract is camelCase, hence the non_snake_case allow. The dead-code allow
//! covers wire fields the manager accepts but does not itself read.
#![allow(non_snake_case, dead_code)]

use serde::{Deserialize, Serialize};

// ---------------------------------------------------------------------------
// CONTRACTS §B  — Provisioner -> MicroVM worker, `POST /exec`
// ---------------------------------------------------------------------------

/// Request body of `POST /exec`.
#[derive(Debug, Clone, Deserialize)]
pub struct ExecRequest {
    pub code: String,
    #[serde(default)]
    pub wantImage: bool,
    /// In-VM exec timeout hint (ms). The fork-server is the primary enforcer.
    #[serde(default = "default_timeout_ms")]
    pub timeoutMs: u64,
}

fn default_timeout_ms() -> u64 {
    10_000
}

/// Response body of `POST /exec` (CONTRACTS §B). The `timings` block is the
/// "invm" block of CONTRACTS §A: the fork-server fills every field EXCEPT
/// `sinceRunHookMs` and `resumedSinceLastExec`, which the manager adds.
#[derive(Debug, Clone, Serialize)]
pub struct ExecResponse {
    pub ok: bool,
    pub stdout: String,
    pub stderr: String,
    #[serde(rename = "imagePngB64")]
    pub image_png_b64: Option<String>,
    pub error: Option<String>,
    pub timings: InvmTimings,
}

/// The full "invm" timings block per CONTRACTS §A/§B.
#[derive(Debug, Clone, Serialize)]
pub struct InvmTimings {
    pub sinceRunHookMs: f64,
    pub dispatchMs: f64,
    pub forkMs: f64,
    pub preforkUsed: bool,
    pub userCodeMs: f64,
    pub firstImportTouchMs: f64,
    pub renderMs: f64,
    pub serializeMs: f64,
    pub totalMs: f64,
    pub resumedSinceLastExec: bool,
}

// ---------------------------------------------------------------------------
// CONTRACTS §I  — Manager <-> Python fork-server over the UDS
// ---------------------------------------------------------------------------

/// Manager -> fork-server request frame. `op` is one of "exec" | "prewarm" |
/// "drain" | "ping". For "exec" the code/wantImage/timeoutMs fields are set.
#[derive(Debug, Clone, Serialize)]
pub struct ForkRequest {
    pub op: &'static str,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub code: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub wantImage: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub timeoutMs: Option<u64>,
}

impl ForkRequest {
    pub fn exec(code: String, want_image: bool, timeout_ms: u64) -> Self {
        Self {
            op: "exec",
            code: Some(code),
            wantImage: Some(want_image),
            timeoutMs: Some(timeout_ms),
        }
    }

    pub fn op_only(op: &'static str) -> Self {
        Self {
            op,
            code: None,
            wantImage: None,
            timeoutMs: None,
        }
    }
}

/// Fork-server -> manager reply frame (CONTRACTS §I). `timings` is present on
/// `exec` replies; for control ops (prewarm/drain/ping) only `ok` is required,
/// so timings is optional here.
#[derive(Debug, Clone, Deserialize)]
pub struct ForkReply {
    pub ok: bool,
    #[serde(default)]
    pub stdout: String,
    #[serde(default)]
    pub stderr: String,
    #[serde(default, rename = "imagePngB64")]
    pub image_png_b64: Option<String>,
    #[serde(default)]
    pub error: Option<String>,
    #[serde(default)]
    pub timings: Option<ForkTimings>,
}

/// The subset of timing fields the fork-server owns (CONTRACTS §I). The manager
/// promotes these into an `InvmTimings`, adding `sinceRunHookMs` and
/// `resumedSinceLastExec`.
#[derive(Debug, Clone, Deserialize, Default)]
pub struct ForkTimings {
    #[serde(default)]
    pub dispatchMs: f64,
    #[serde(default)]
    pub forkMs: f64,
    #[serde(default)]
    pub preforkUsed: bool,
    #[serde(default)]
    pub userCodeMs: f64,
    #[serde(default)]
    pub firstImportTouchMs: f64,
    #[serde(default)]
    pub renderMs: f64,
    #[serde(default)]
    pub serializeMs: f64,
    #[serde(default)]
    pub totalMs: f64,
}
