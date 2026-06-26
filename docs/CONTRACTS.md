# CONTRACTS — exact interfaces every component binds to

These are FROZEN. Frontend, provisioner, microvm worker, infra, and harness must all match byte-for-byte
(field names, enum values, resource names, env var names). If you change one, change all and update this
file.

## A. Browser → Provisioner (Lambda Function URL, `POST /`, JSON, CORS-enabled)
Request:
```jsonc
{
  "action":   "run" | "reuse" | "suspend" | "terminate",  // run=cold create+exec; reuse=exec on existing (hot/auto-resume)
  "variant":  "base" | "mpl" | "sci",
  "lifecycle":"ephemeral" | "idle30" | "idle60" | "max5" | "max10",
  "code":     "string (python source)",                    // required for run|reuse
  "microvmId":"mvm-...",                                    // required for reuse|suspend|terminate
  "endpoint": "mvm-....lambda-microvm.<region>.on.aws",    // optional cache for reuse (else provisioner re-derives)
  "wantImage":true,                                          // capture matplotlib figure as PNG
  "timeoutMs":10000                                          // in-VM exec timeout hint
}
```
Response:
```jsonc
{
  "ok": true,
  "microvmId": "mvm-...",
  "endpoint": "mvm-....on.aws",
  "state": "RUNNING" | "SUSPENDED" | "TERMINATED" | "PENDING",
  "regime": "cold-create" | "warm-resume" | "hot" | "control",
  "result": {                                  // null for suspend/terminate
    "ok": true, "stdout": "", "stderr": "", "imagePngB64": "" | null, "error": null
  },
  "timings": {
    "provisioner": {                           // Go monotonic, ms (floats ok)
      "lambdaCold": false, "runMicrovmMs": 0, "tokenMintMs": 0, "tokenOverlapMs": 0,
      "execRttMs": 0, "firstAttemptHeld": true, "execRetries": 0,
      "totalMs": 0
    },
    "invm": {                                  // CLOCK_MONOTONIC, ms; echoed from worker (null if control action)
      "sinceRunHookMs": 0, "dispatchMs": 0, "forkMs": 0, "preforkUsed": true,
      "userCodeMs": 0, "firstImportTouchMs": 0, "renderMs": 0, "serializeMs": 0, "totalMs": 0,
      "resumedSinceLastExec": false            // worker sets true if /resume fired since the previous exec → provisioner labels regime "warm-resume" (no GetMicrovm poll needed)
    }
  },
  "costEstimateUsd": 0.0,
  "error": null
}
```
Note: the **browser** wraps each call in `performance.now()` for end-to-end; it does NOT depend on these
server timings for its own clock.

## B. Provisioner → MicroVM worker (data plane, `POST /exec`, header `X-aws-proxy-auth`)
Request:
```jsonc
{ "code": "string", "wantImage": true, "timeoutMs": 10000 }
```
Response (HTTP 200; non-200 = worker/infra error):
```jsonc
{
  "ok": true, "stdout": "", "stderr": "", "imagePngB64": "" | null, "error": null,
  "timings": {     // CLOCK_MONOTONIC ms — the "invm" block above, same field names
    "sinceRunHookMs": 0, "dispatchMs": 0, "forkMs": 0, "preforkUsed": true,
    "userCodeMs": 0, "firstImportTouchMs": 0, "renderMs": 0, "serializeMs": 0, "totalMs": 0,
    "resumedSinceLastExec": false
  }
}
```
Also: `GET /healthz` → 200 `{"ok":true}`.

## C. Lifecycle hooks (Lambda → worker; FIXED paths on `hooks.port` = 9000)
`POST /aws/lambda-microvms/runtime/v1/{ready,validate,run,resume,suspend,terminate}`
> `hooks.port` MUST be **9000**, not 8080: 8080 is AWS's data-plane endpoint
> default, and AWS's build-time hook POST never reaches an app whose `hooks.port`
> is 8080 (`Ready hook invocation timed out` with the app provably listening). The
> manager binds BOTH ports — **9000** = hooks, **8080** = data-plane `/exec` — and
> the ready hook returns 200 unconditionally (mirrors the AWS sample).
- `run` body: `{ "microvmId": "...", "runHookPayload": "..." }`. Our runHookPayload is a JSON string
  `{ "sessionId": "...", "stampRunDone": true }`. The worker uses it only to stamp `t_run_done`
  (monotonic) so the first `/exec` can report `sinceRunHookMs`; the user code travels on the `/exec`
  channel.
- All return 200 on success; `ready`/`validate` return 503 (immediately, don't hold) until warm.
- `validate`: run ONE mock exec (`print(1)` for base; tiny plot for mpl/sci) so Lambda samples & prefetches
  hot snapshot regions.

## D. Resource names (Terraform creates; provisioner/harness reference) — `<acct>` = your AWS account ID
| Thing | Name / pattern |
|---|---|
| S3 artifact bucket | `microvm-bench-artifacts-<region>-<acct>` |
| Build role | `microvm-bench-build-role` (global) |
| Exec role | `microvm-bench-exec-role` (global) |
| Provisioner role | `microvm-bench-provisioner-role` (global) |
| Reaper role | `microvm-bench-reaper-role` (global) |
| Provisioner Lambda | `microvm-bench-provisioner` (per region) |
| Reaper Lambda | `microvm-bench-reaper` (per region) |
| DynamoDB table | `microvm-bench-results` (global; us-east-1 home) |
| SPA bucket | `microvm-bench-spa-<acct>` (private; readable only via CloudFront OAC) |
| CloudFront | one global distribution: SPA (S3 origin) + `/api/use1/*` + `/api/usw2/*` (OAC SigV4 → the two provisioner Function URLs) |
| Image names | `microvm-bench-base` · `microvm-bench-mpl` · `microvm-bench-sci` (per region) |
| Image ARN | `arn:aws:lambda:<region>:<acct>:microvm-image:microvm-bench-<variant>` |
| Common tag | `Project=microvm-bench` on every Terraform resource (cost allocation; microVMs carry no per-VM tag, so the reaper matches by image ARN) |
| Ingress connector | `arn:aws:lambda:<region>:aws:network-connector:aws-network-connector:ALL_INGRESS` |
| Egress connector | `arn:aws:lambda:<region>:aws:network-connector:aws-network-connector:INTERNET_EGRESS` |

## E. Provisioner Lambda env vars (Terraform sets; updated by build-image.sh after image creation)
```
REGION                = us-east-1 | us-west-2
RESULTS_TABLE         = microvm-bench-results
EXEC_ROLE_ARN         = arn:aws:iam::<acct>:role/microvm-bench-exec-role
INGRESS_CONNECTOR_ARN = arn:aws:lambda:<region>:aws:network-connector:aws-network-connector:ALL_INGRESS
EGRESS_CONNECTOR_ARN  = arn:aws:lambda:<region>:aws:network-connector:aws-network-connector:INTERNET_EGRESS
IMAGE_ARN_BASE        = arn:aws:lambda:<region>:<acct>:microvm-image:microvm-bench-base
IMAGE_ARN_MPL         = arn:aws:lambda:<region>:<acct>:microvm-image:microvm-bench-mpl
IMAGE_ARN_SCI         = arn:aws:lambda:<region>:<acct>:microvm-image:microvm-bench-sci
EXEC_PORT             = 8080
MICROVM_LOG_GROUP     = /microvm-bench/microvm/<region>   # in-VM CloudWatch trail (default on)
```

## F. DynamoDB `microvm-bench-results` item shape
PK `runId` (string, ULID-ish from provisioner), plus: `ts` (epoch ms), `region`, `variant`, `regime`,
`lifecycle`, `microvmId`, `firstAttemptHeld` (bool), `execRetries` (n), and a flattened `timings` map +
`costEstimateUsd`. On-demand capacity. GSI `byVariantRegion` (PK `variantRegion`, SK `ts`) for the
harness to aggregate. Provisioner writes best-effort (never fail the request on a Dynamo error).

## G. Lifecycle preset → RunMicrovm params (provisioner maps `lifecycle` → these)
| preset | maxIdleDurationSeconds | suspendedDurationSeconds | autoResumeEnabled | maximumDurationInSeconds | post-exec |
|---|---|---|---|---|---|
| ephemeral | 60  | 0   | false | 120 | provisioner calls TerminateMicrovm after exec |
| idle30    | 60  | 300 | true  | 600 | leave running (auto-suspends in 60 s — see floor below) |
| idle60    | 60  | 300 | true  | 600 | leave running |
| max5      | 60  | 240 | true  | 300 | leave running |
| max10     | 120 | 480 | true  | 600 | leave running |
Auth token: `expirationInMinutes: 30`, `allowedPorts: [{allPorts:{}}]` (max is 60).

> **API FLOOR (verified live against RunMicrovm, GA 2026-06):**
> `idlePolicy.maxIdleDurationSeconds` must be **>= 60** — RunMicrovm rejects 30 with a
> `ValidationException`. So a true sub-60 s idle threshold is NOT expressible; `ephemeral`
> and `idle30` were bumped 30→60 (the `idle30` key is retained for the frozen contract /
> UI labels but now behaves like `idle60`). The idle-threshold experiment is bounded by
> this floor — document it in results.

## H. Variant → sample code (frontend prefills; worker can run any)
- base: `print(sum(i*i for i in range(10_000)))`
- mpl:  numpy linspace + `matplotlib` sine plot → `savefig(buf, format="png")`
- sci:  pandas DataFrame + `seaborn` barplot/heatmap → PNG
(Worker captures the current matplotlib figure if `wantImage` and a figure exists.)

## I. Rust manager ↔ Python fork-server (Unix domain socket, FROZEN)
Socket path: `/run/microvm-bench/forkserver.sock` (manager creates dir; fork-server binds; manager connects).
Framing on BOTH directions: **4-byte big-endian unsigned length prefix**, then that many bytes of UTF-8 JSON.
- Manager → fork-server (one request per connection or persistent; use one connection per exec for simplicity):
  ```jsonc
  { "op": "exec", "code": "string", "wantImage": true, "timeoutMs": 10000 }
  // also: { "op": "prewarm" }  (force-prefork a child)  · { "op": "ping" }  → { "ok": true }
  //       { "op": "drain" }    (kill the idle child before a suspend snapshot)  → { "ok": true }
  ```
- Fork-server → manager:
  ```jsonc
  { "ok": true, "stdout": "", "stderr": "", "imagePngB64": null, "error": null,
    "timings": { "dispatchMs":0, "forkMs":0, "preforkUsed":true, "userCodeMs":0,
                 "firstImportTouchMs":0, "renderMs":0, "serializeMs":0, "totalMs":0 } }
  ```
Ownership of timing fields: **fork-server** fills everything in `timings` EXCEPT `sinceRunHookMs` and
`resumedSinceLastExec`, which the **manager** adds (it owns the `/run` and `/resume` hook stamps) before
replying to the provisioner per §B. Timeout enforcement: the **fork-server** is the primary enforcer — it
`SIGKILL`s the child's process group on `timeoutMs` and returns `{ok:false,error:"timeout"}`; the
**manager** keeps a longer backstop deadline on the UDS read and, if the fork-server itself wedges,
kills+relaunches the fork-server (never leaves a wedged process). Pre-fork invariant: the fork-server
always keeps exactly one idle child blocked on a pipe; `exec` hands the job to that child (so `forkMs≈0`,
`preforkUsed=true`) then immediately forks the replacement.
