# AWS MicroVM Sandbox

Empirical measurement of **AWS Lambda MicroVMs** (Firecracker microVM snapshots, GA 2026-06-22) as a
backend for running **untrusted Python code** with a data-viz stack (numpy / pandas / matplotlib /
seaborn). The real question isn't whether an already-running container is fast — it obviously is. It's
whether **snapshots** let you *avoid keeping one warm*: how fast is a **cold snapshot start**, and how
fast is **resume after idle** — because those decide whether you can scale to zero and still feel
instant.

This is a self-contained measurement workspace (internal codename `microvm-bench`): a Go provisioner
(Lambda Function URL), a Rust in-VM manager supervising a warm Python fork-server, three image
variants, Terraform infra in two regions, a browser UI, and a Go benchmark harness. Everything is
wired to measure **time-to-execute** with real clocks at every edge.

> **Gate:** total time-to-execute reliably **< 2 s** on the paths that matter when you *don't* keep a
> VM warm — cold snapshot start (~2–2.9 s, network-floor bound) and resume-from-idle (~0.7–1.4 s, the
> real lever). A warm RUNNING VM is the trivial floor (~55 ms). See [Results](#results-measured).

---

## Results (measured)

Numbers below are the **provisioner-side** clock (Go monotonic, request-receipt to response — the
precise instrument; it excludes the browser↔region network leg), aggregated from CloudWatch EMF over
**n ≈ 236 runs** after the most recent deployment (both regions, all three variants). The behavior was
also **verified end-to-end in a real browser** in both regions — the browser round-trip tracks these
plus the user→region RTT. `total_ms` is the provisioner's full critical path: `RunMicrovm` (cold only) +
auth-token mint + send-and-hold `POST /exec` round-trip.

| Regime | Variant | us-west-2 p50 / p90 | us-east-1 p50 / p90 | inbound request held? |
|---|---|---|---|---|
| **hot** (reuse RUNNING VM) | base | **61** / 82 ms | ~54 ms | 100 % |
| | mpl | 191 / 205 ms | — | 100 % |
| | sci | 445 / 478 ms | 457 ms | 100 % |
| **cold-create** (fresh VM) | base | **2021** / 2572 ms (min 1439) | 2568 / 3117 ms (min 1844) | ~6–9 % |
| | mpl | 2195 / 2681 ms | 2739 / 3033 ms | ~6–9 % |
| | sci | 2371 / 2841 ms (max 3851) | 2853 / 4096 ms | ~6–9 % |
| **warm-resume** (suspend→resume) | base | **692** ms (min 636) | — | ~100 % |
| | sci | 1358 / 1597 ms (min 1019) | — | ~91 % |

What the data says (the point is the cold/resume paths — a warm VM being fast is a given):

- **Cold snapshot start lands ~2–2.9 s, and it's bound by inbound-endpoint routing, not the microVM.**
  `RunMicrovm` returns in ~150–230 ms and the snapshot's first exec is already warm (<1 ms `base` to
  ~400 ms `sci` render — imports are resident in the snapshot). The dominant cost is the data-plane
  endpoint becoming routable: a freshly-created `PENDING→RUNNING` VM **holds** the first inbound
  `/exec` only ~6–9 % of the time, so a cold request typically eats one bounded retry — most of the 2 s.
- **Resume-from-idle is the real lever: ~0.7 s (`base`) to ~1.4 s (`sci`), and it holds the request.**
  Auto-resume holds the inbound `/exec` through `SUSPENDED→RUNNING` (~91–100 %), so resume beats
  cold-create and clears the gate. This is what makes "scale to zero, wake fast" viable — a **suspended
  pool** is the path to sub-2-s first touch, *not* optimizing cold-create. Resume latency tracks the
  memory-snapshot size (412 MiB `base` → ~0.7 s, 552 MiB `sci` → ~1.4 s; see
  [`SIZES.md`](microvm/images/SIZES.md)).
- **A warm RUNNING VM is the trivial floor: ~55 ms (`base`).** Expected for an already-listening
  process — the baseline, not a finding. The `mpl`/`sci` deltas (~190 / ~450 ms) are almost entirely
  **in-VM render** (matplotlib/seaborn drawing the PNG), not infrastructure.
- **Auth-token mint: hidden on cold, but re-minted every request (a known inefficiency).**
  `CreateMicrovmAuthToken` is fired the instant `RunMicrovm` returns and fully overlaps boot on cold
  (`token_overlap_ms` ≫ `token_mint_ms`, free there). But the provisioner mints a fresh token on
  **every** request — including hot/resume, where there's no boot to hide behind — even though tokens
  are valid 30 min. Production would cache the token per-`microvmId` until near expiry; it's left
  per-request here for measurement simplicity.
- **Region / "AWS got faster".** us-west-2 cold ran ~0.5 s tighter than us-east-1 in this sample; the
  in-VM `endpoint_lag_ms` on recent cold runs is ~140 ms (vs ~1.25 s in earlier sessions), consistent
  with AWS-side endpoint-routing improvements.

> Caveat: these are the provisioner-side clock (the precise instrument) and reflect one deployment's
> traffic — exact browser round-trip numbers weren't logged, though the behavior was confirmed live in
> both regions. Treat them as the shape of the system, not a benchmark SLA.

---

## Architecture

```
Browser  (performance.now — the only client clock)
  │  GET / static SPA            POST /api/use1|/api/usw2  (region by path)
  ▼
CloudFront distribution
  ├── S3 origin (private, OAC)  →  the Vite-built SPA
  └── Lambda-URL origins (OAC, SigV4-signed by CloudFront)  →  regional provisioner Function URLs
  ▼
Provisioner Lambda   (Go, one per region: us-east-1, us-west-2; Function URL, AWS_IAM)
  │  1. RunMicrovm (cold) | reuse RUNNING microvmId (hot)      → run_microvm_ms
  │  2. CreateMicrovmAuthToken  (overlaps boot)                → token_mint_ms / token_overlap_ms
  │  3. POST https://<id>.lambda-microvm.<region>.on.aws/exec  (X-aws-proxy-auth header)
  │        └─ SEND-AND-HOLD through PENDING→RUNNING / SUSPENDED→RUNNING.  No get-microvm polling.
  ▼
MicroVM   ARM64 / Graviton   (Rust manager :8080  +  warm Python fork-server)
  │  manager hands code to a PRE-FORKED idle child (first exec pays no fork cost)
  │  child runs untrusted code under rlimits → renders PNG → returns CLOCK_MONOTONIC timings
  ▼
Provisioner  →  DynamoDB (durable result row)  +  CloudWatch EMF (metrics/dashboard)  →  Browser
```

Three real clocks at the edges (you cannot stopwatch inside an edge function that freezes time):
browser `performance.now()`, provisioner Go monotonic, in-VM `CLOCK_MONOTONIC`. The frontend is
**100 % AWS** — CloudFront + S3 + Lambda Function URLs, no third-party in the request path.

**Why this shape:** `RunMicrovm` returns `PENDING` and the microVM is `RUNNING` only once its `/run`
hook returns. Polling `get-microvm` is a rate-limited anti-pattern, so the provisioner relies on the
data-plane endpoint **holding** the inbound request through the state transition (measured via
`first_attempt_held`), with a bounded data-plane retry as fallback. See [`docs/CONTRACTS.md`](docs/CONTRACTS.md) §B.

---

## Stack / dependencies

| Component | Dir | Language / runtime | Key dependencies |
|---|---|---|---|
| **Provisioner + reaper** | `provisioner/` | Go 1.26, ARM64 Lambda | `aws-lambda-go`, `aws-sdk-go-v2` (`lambdamicrovms` v1.0.0, `dynamodb`, `config`), `oklog/ulid` |
| **In-VM manager** | `microvm/manager/` | Rust 2021 (1.96) | `axum` 0.8, `tokio`, `nix` (process/signal), `serde`, `tracing`; release = thin-LTO + `panic=abort` + stripped |
| **Fork-server** | `microvm/forkserver/` | CPython 3.13 (uv-managed standalone) | `numpy`, `matplotlib` (Agg), `pandas`, `seaborn` — imported once in the warm parent |
| **Images** | `microvm/images/` | multi-stage Docker, ARM64 | `rust:1.96-bookworm` (builder) → `debian-slim` + `uv` (py-builder) → `public.ecr.aws/lambda/microvms:al2023-minimal` (final) |
| **Infra** | `infra/` | Terraform (AWS provider ~5.0), local state | per-region module (Lambda + Function URL, S3, CloudWatch, reaper + EventBridge) · global (IAM, DynamoDB) · frontend (CloudFront + S3 + OAC) |
| **Frontend** | `frontend/` | TypeScript 5.8 + Vite 6 | CodeMirror 6 (`@codemirror/*`, `lang-python`) — served from S3 behind CloudFront |
| **Harness** | `harness/` | Go 1.26 CLI | `aws-sdk-go-v2` (SigV4 to the Function URLs) |

### In-VM process model (safety-first)

The image ENTRYPOINT is the **Rust manager**. It binds HTTP on `:8080` (data-plane `/exec` + `/healthz`)
and serves the lifecycle hooks on `:9000`, and supervises the **Python fork-server** over a Unix-domain
socket. The fork-server imports the heavy libraries **once** at startup (warm parent, BLAS pinned to a
single thread, matplotlib forced to `Agg`), keeps **one idle child already forked and blocked** so the
first `/exec` pays no fork cost, then `fork()`s per request. Each child runs untrusted code in its own
process group under rlimits (CPU, address-space, FSIZE, NOFILE) and is `SIGKILL`-ed on timeout/crash;
COW means every child starts with all libraries resident. The snapshot captures the **idle warm parent**
— imports + on-disk caches + shared pages, *not* execution (user code only arrives at run time). See
[`microvm/images/BUILD-NOTES.md`](microvm/images/BUILD-NOTES.md) for the snapshot shake-down.

---

## Repo layout

| Path | Role |
|---|---|
| `provisioner/` | Lambda Function URL handler — orchestrates the microVM lifecycle, merges + emits timings, reaper |
| `microvm/manager/` | In-VM HTTP server, lifecycle hooks, fork-server supervisor (Rust) |
| `microvm/forkserver/` | Warm Python fork-server + smoke test |
| `microvm/images/` | 3 ARM64 image variants + snapshot shake-down (`shrink.sh`) + `BUILD-NOTES.md` |
| `microvm/samples/` | Example user-code payloads per variant |
| `infra/` | Terraform: IAM, S3, Lambda, DynamoDB, EventBridge, CloudWatch, CloudFront/S3 frontend |
| `frontend/` | Browser UI (CodeMirror editor, region/variant/lifecycle controls, timing table, PNG render) |
| `harness/` | Go CLI: `run` (benchmark matrix), `estimate` (offline cost), `reap` |
| `scripts/` | `bootstrap.sh`, `build-image.sh`, `deploy-frontend.sh`, `reap.sh` |
| `docs/` | `API-FACTS.md` (authoritative AWS surface), `CONTRACTS.md` (frozen interfaces) |

---

## Prerequisites

| Tool | Version | Notes |
|---|---|---|
| AWS CLI | v2.35+ | `aws lambda-microvms` + `aws lambda-core` namespaces |
| AWS profile | `microvm-bench` | `aws configure --profile microvm-bench` (admin while experimenting) |
| Go | 1.26+ | provisioner + harness |
| Rust + cargo | 1.96+ | in-VM manager (built server-side; local repro optional) |
| Docker + buildx | 29.1+ | local ARM64 build reproduction (AWS does the real build on Graviton) |
| Terraform | 1.x | infra provisioning (local state) |
| pnpm | 10+ (Node 24) | frontend |
| jq | any | used by scripts |

Regions under test: **us-east-1** and **us-west-2** (ARM64/Graviton only). MicroVM **images are
regional** — built once per region.

---

## Setup (ordered runbook)

```bash
# 0. Clone and configure
git clone <repo> aws-microvm-sandbox && cd aws-microvm-sandbox
cp .env.example .env                       # set AWS_PROFILE / AWS_REGION (optional overrides)
aws configure --profile microvm-bench
#    set var.account_id for Terraform (auto-derived in scripts via `aws sts get-caller-identity`):
echo 'account_id = "<your-account-id>"' > infra/terraform.tfvars

# 1. One-shot bootstrap (runs steps 2–6 with cost warnings)
bash scripts/bootstrap.sh

# --- or run each step manually ---
make deploy-infra        # 2. IAM, S3, Lambda, DynamoDB, EventBridge, CloudFront/S3 frontend
make binfmt              # 3. register arm64 binfmt for local docker cross-builds
make build-provisioner   # 4. cross-compile provisioner + reaper (arm64) → zip
make build-images        # 5. build 3 variants × 2 regions on Graviton (~5–15 min each)
make deploy-frontend     # 6. vite build → S3 sync → CloudFront invalidate
```

`scripts/build-image.sh` prints each image ARN and writes
`results/image-metadata-<region>-<variant>.json`; the provisioner picks up the latest **active** image
version automatically (no env change needed on rebuild).

---

## Daily workflow

```bash
make test       # run the benchmark harness (N=3 samples, --budget-usd cap)
make estimate   # offline cost estimate (no AWS calls)
make reap       # terminate all bench microVMs (manual reap)
make verify     # go vet · cargo check · py_compile · tsc
make fmt        # format all source
```

A **reaper** Lambda (EventBridge, every 5 min) also terminates any `Project=microvm-bench` microVM past
a TTL (default 15 min) as a leak backstop.

---

## Experiment matrix

The browser UI and harness expose:

| Axis | Options |
|---|---|
| **Variant** | `base` (CPython stdlib, 512 MiB) · `mpl` (+ numpy + matplotlib, 1 GiB) · `sci` (+ pandas + seaborn, 1 GiB) |
| **Region** | `us-east-1` · `us-west-2` |
| **Lifecycle preset** | `ephemeral` · `idle30` · `idle60` · `max5` · `max10` (idle policy + max-duration on `RunMicrovm`) |
| **Action** | `Run (cold create)` · `Run again (hot)` · `Run after resume` · `Suspend now` · `Terminate` |

### Reading the timing breakdown

| Layer | Clock | Fields |
|---|---|---|
| **Client** | `performance.now()` | `totalMs` (end-to-end incl. network) |
| **Provisioner** | Go monotonic | `runMicrovmMs`, `tokenMintMs`, `tokenOverlapMs`, `execRttMs`, `firstAttemptHeld`, `execRetries`, `totalMs` |
| **In-VM** | `CLOCK_MONOTONIC` | `sinceRunHookMs`, `forkMs`, `userCodeMs`, `renderMs`, `invmTotalMs` |

- `tokenOverlapMs` — how much of the auth-token mint was hidden behind boot (positive = free).
- `firstAttemptHeld` — the cold `/exec` POST succeeded held through `PENDING→RUNNING` (no retry).
- `sinceRunHookMs` — in-VM time from the `/run` hook completing to the first exec arriving.

---

## Authoritative docs

- **[`docs/API-FACTS.md`](docs/API-FACTS.md)** — the verified AWS Lambda MicroVMs API surface, extracted
  from the real CLI + Go SDK.
- **[`docs/CONTRACTS.md`](docs/CONTRACTS.md)** — frozen interface schemas (field names, enum values, env
  vars, resource names) every component binds to.

A skill capturing the operational knowledge lives under `.claude/skills/aws-lambda-microvms/`.

---

## Status

A measurement workspace, not a product. The latency picture above is settled; known gaps if this were
taken to production: the provisioner mints a fresh auth token on **every** request when it should cache
one per `microvmId` until near the 30-min expiry (a free win on hot/resume); suspend/resume is
exercised by the harness but not yet wired into the provisioner action set or the UI; and the
suspended-pool warm-start (the sub-2-s-on-first-touch lever) is designed but unbuilt.
