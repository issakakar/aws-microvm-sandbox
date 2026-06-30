# Northflank vs AWS Lambda MicroVMs — for Avlo's ephemeral Python executor

> Research note (2026-06-30). Decision context: a backend for running **untrusted, multi-tenant
> Python** (numpy / pandas / matplotlib / seaborn data-viz) for Avlo's code blocks. Pattern:
> spin up an isolated env, run for **~2–3 min max, then destroy**. **No** reliance on
> suspend/resume snapshots (everything ephemeral). Cost-sensitive. Strong tenant isolation required.
>
> This evaluates **Northflank** honestly against the AWS Lambda MicroVMs path already built and
> measured in this repo. Northflank's own docs are marketing-heavy, so every claim below is tagged
> **[measured]** (independent/third-party), **[claimed]** (vendor, no methodology),
> **[estimate]**, or **[inference]**, and marketing is separated from verifiable fact.

---

## TL;DR

- **Northflank is genuinely interesting for two concrete reasons — cost and burst-provisioning
  throughput — and roughly a wash on everything else for your keep-alive-2–3-min pattern.** It is
  **not** a clear win, and it carries real vendor-maturity and footgun risk.
- **Cost:** Northflank managed compute is **~3.8× cheaper** than Lambda MicroVMs at the same nominal
  size (Lambda MicroVMs bills a premium `$0.0997/vCPU-hr`); BYOC is cheaper still on the platform
  fee. Per-second, **no per-run minimum**. **[measured]**
- **Burst scale:** Northflank provisioned **100,000 concurrent sandboxes cold in 24 s, 0 failures**
  (independent benchmark) — versus AWS's **hard `RunMicrovm` limit of 5/sec per account per region**.
  If Avlo's "run" traffic is spiky, this is the single biggest functional difference. **[measured]**
- **Isolation:** Equivalent *class* of boundary (per-execution microVM, dedicated guest kernel) —
  **but only if you use Northflank's Sandboxes product with Kata + Firecracker/Cloud-Hypervisor.**
  Plain Northflank Services/Jobs are shared-kernel `runc` containers and are **not** a safe boundary
  for untrusted code (their own engineers say so). Easy to footgun. **[measured]**
- **Startup:** Northflank container-ready is **sub-second** and independently verified — but the
  benchmarks run a *trivial* command. **Northflank has no memory snapshot**, so your heavy
  `numpy/pandas/matplotlib/seaborn` import (~1–3 s cold) is paid **live** on each fresh sandbox's
  first exec. AWS's **free build-time snapshot** eliminates exactly that. For the keep-alive pattern
  it amortizes within a session; for single-shot it favors AWS.
- **Snapshotting:** Northflank has **none** for compute (its "pause/resume" is scale-to-zero, i.e. a
  cold container restart). A non-issue for you — you weren't snapshotting — but it's *why* there's no
  free warm-import.
- **Maturity:** Northflank is a **small, well-funded startup** (~$24.9M, ~19–29 people) with a
  recurring **"can't create resources in region"** outage pattern in 2025–2026 — the exact hot path
  a create-on-demand system depends on — and a **default 1000 API req/hr limit** you'd have to get
  raised. You're trading hyperscaler reliability for cost + scale.

**Recommendation:** Worth a benchmark — but benchmark the *right* things (heavy-image cold first-touch,
warm fork-server in-session, burst create rate, BYOC cost). Your AWS path already works and meets the
<2 s gate; Northflank is a **cost + burst-scale optimization**, most compelling as **BYOC-on-AWS**
(Firecracker isolation in your own VPC, no 5/s ceiling, per-second billing) rather than as a wholesale
swap to their managed multi-tenant cloud.

---

## The two platforms at a glance

| Dimension | **AWS Lambda MicroVMs** (this repo's path) | **Northflank** (Sandboxes product) |
|---|---|---|
| What it is | Serverless Firecracker microVM primitive (GA **2026-06-22**) | Full-stack **PaaS on Kubernetes**; "Sandboxes" is one product |
| Isolation | Firecracker microVM, dedicated kernel, **no shared kernel** — native, always on | Kata + **Cloud Hypervisor**(primary)/**Firecracker** microVM, or gVisor — **opt-in**; default is shared-kernel `runc` |
| Cold start (your stack) | **~2.0–2.9 s** cold-create (endpoint-routing bound), warm-import **free** via build snapshot | **~0.3–0.75 s** container-ready, **+ ~1–3 s live Python import** (no snapshot) |
| Hot reuse (in session) | ~55 ms (base) → ~450 ms (sci, mostly render) | sub-second; warm `exec` into a live sandbox |
| Burst create limit | **5 `RunMicrovm`/sec / account / region (hard)** | 100k concurrent in 24 s **[measured]**; default **1000 API req/hr** (raise via support) |
| Compute price (1 vCPU/2 GB) | `$0.0997/vCPU-hr` + `$0.0132/GB-hr` → **~$0.0063 / 3-min job** | `$0.01667/vCPU-hr` + `$0.00833/GB-hr` → **~$0.0017 / 3-min job**; BYOC cheaper |
| Billing granularity | Per-second (VM billed incl. boot) | **Per-second, no minimum** |
| Snapshots | Build snapshot (free warm start) + optional suspend/resume (write-cost — you skip it) | **None for compute** (DB add-ons only) |
| Max lifetime | **8 hr** | No forced limit |
| Maturity / reliability | Hyperscaler; but the *product* is **8 days old**, 5 regions, ARM64-only | Startup (founded 2019, ~$24.9 M, ~19–29 ppl); 68+ outages/4 yr, region-create incidents |
| Lock-in | AWS | OCI containers + **BYOC** (lower lock-in); Templates are proprietary |
| SDK/DX | You build the provisioner (done, in this repo) | General REST/JS API + CLI + Terraform; **no Python SDK, no turnkey `sandbox.run()`** |

---

## 1. Isolation & security (the crux for untrusted multi-tenant Python)

**Verdict: equivalent class of boundary to AWS Firecracker — but it's opt-in and easy to get wrong.**

- Northflank's **default** Services/Jobs run as `runc` containers sharing the host kernel. Their own
  engineering blog is blunt: shared-kernel containers *"are not sufficient"* for *"code generated by
  an LLM, submitted by a user, or coming from any external source."* **[measured]**
- Strong isolation is selected per-workload via Kubernetes `RuntimeClass`, and packaged as the
  **Sandboxes** product:
  - **Kata Containers** → each workload in its **own microVM with a dedicated guest kernel** (KVM),
    backed by **Cloud Hypervisor** (their stated primary VMM) or **Firecracker** (~125 ms boot).
  - **gVisor** (`runsc`) → user-space kernel; lighter, moderate-trust. **GPU on their managed cloud
    defaults to gVisor**, not a full microVM (only matters if you need GPU).
  - Northflank's own recommendation for genuinely untrusted code: *"Kata Containers with Firecracker
    or Cloud Hypervisor is the right default."* **[measured]**
- So **what isolates one tenant from another, configured correctly, is a separate guest kernel inside
  a hardware-virtualized microVM** — the same kind of boundary AWS Lambda MicroVMs gives you natively.
- **BYOC** (bring-your-own-cloud): Northflank's *control plane* stays in their account; the *data
  plane* (nodes, your untrusted workloads, data) runs **in your own AWS/GCP/Azure VPC**, your KMS
  keys, your egress policy. Blast radius is confined to **your** account. *"Northflank never has
  access to encryption keys or encrypted data."* **[claimed/measured]**
- Compliance: **SOC 2 Type 2** on managed cloud (report gated, not independently seen); other
  frameworks (HIPAA/ISO/FedRAMP) are framed as **inherited via BYOC** from your own cloud, not held
  by Northflank's multi-tenant platform. **[claimed]**
- ⚠️ **Honest gaps:** no public threat model / red-team / escape-posture writeup for their specific
  implementation; "prevent container escape" is asserted, not audited. The marketing
  **"2M+ microVMs/month since 2021"** is unverified. The independent benchmark (below) validates
  *provisioning*, **not** isolation strength.

**Footgun to internalize:** "Northflank isolates untrusted code" is true *only inside the Sandboxes
product with a microVM runtime selected*. A plain Service/Job does not. AWS Lambda MicroVMs has no
such mode confusion — isolation is the always-on default.

---

## 2. Startup performance (+ the Python-import nuance)

**Northflank container-ready is genuinely fast and independently measured** — ComputeSDK leaderboard
(June 30 2026, fresh sandbox each time, no warm pool, prebuilt image, runs `node -v`):

| Mode | Median TTI | P95 | P99 | Success |
|---|---|---|---|---|
| Sequential | 159 ms | 223 ms | 229 ms | 100% |
| Staggered | 144 ms | 217 ms | 256 ms | 100% |
| Burst (100 concurrent) | 289 ms | 371 ms | 388 ms | 100% |

And the **Scale Invitational**: **100,000 concurrent sandboxes cold in 24 s, 0 failures**, P99 allocate
566 ms / readiness 733 ms — **beating E2B** (2.69 s / 1.42 s) **and Modal** (1.51 s / 3.67 s). **[measured]**

**The critical caveat for *your* workload:** those benchmarks run a trivial no-op. They measure
"container ready + exec a no-op." Your stack is `numpy + pandas + matplotlib + seaborn`, whose
**cold import is ~1–3 s**. Because **Northflank has no memory snapshot**, a fresh sandbox pays that
import **live on the first exec**. On AWS Lambda MicroVMs, the **build-time snapshot** (free — distinct
from the suspend-snapshot you're skipping) captures the **warm Python parent with imports resident in
RAM**, so every cold microVM's first exec renders immediately.

Net first-touch on a **fresh** environment is roughly comparable for the heavy stack:

| | Cold first-touch (fresh env, heavy data-viz) | In-session repeat (warm) |
|---|---|---|
| AWS Lambda MicroVMs | ~2.0–2.9 s (incl. warm import + render) | ~55 ms → ~450 ms |
| Northflank Sandbox | ~0.5–0.75 s ready **+ ~1–3 s live import** + render ≈ **~2–4 s** | sub-second (if warm fork-server kept alive) |

For your **keep-alive-2–3-min** model, the import is paid **once per session** on both — so they
converge once a session is warm. The free-warm-import advantage only decisively favors AWS for
**single-shot, destroy-immediately** sessions, or very high churn of fresh envs.

**Operational notes:**
- Use the **Sandboxes API** (`sandbox.create()` from a **prebuilt** Python image, then `exec`), **not
  run-to-completion Jobs** — Jobs are image-pull-dominated (third-party **[estimate]** ~5–15 s cold).
- **Warm pools are not a native managed feature** — you'd build pool sizing + drain/refill yourself
  and pay idle. (Same as you'd do on AWS; AWS at least lets a *suspended* pool resume in ~0.7–1.4 s,
  whereas a Northflank warm pool means keeping sandboxes **running**.)
- **First-image-pull onto a cold node** is the one latency nobody publishes — your real tail-risk.
  Mitigate by pinning a prebuilt image and keeping it warm on nodes.

---

## 3. Snapshotting

**Northflank offers no memory snapshot, no suspend/resume, no CRIU checkpoint-restore, no
fork-from-snapshot, and no warm-template for compute.** Its "pause/resume" is **scale-to-zero** — the
container is killed and cold-restarted from the image; only mounted volumes survive. Real snapshots
exist **only for database add-ons** (incremental disk backups), not your execution workloads. **[measured]**

For your throwaway pattern this is a **non-issue** — you explicitly weren't going to snapshot. Two
second-order consequences:
- **Mild plus:** no snapshot-*write* cost (the thing you're avoiding on AWS by skipping suspend/resume).
- **The minus from §2:** no snapshot also means **no free warm-import** on cold start. AWS's build
  snapshot is doing real work for your heavy stack that Northflank can't replicate without warm pools.

> Reminder on the AWS side: the snapshot you're declining is the **runtime suspend/resume** one
> (`$0.0038/GB` write). The **build-time** snapshot is free and automatic and is what makes Lambda
> MicroVM cold-creates start warm. Don't conflate the two — you're keeping the valuable one for free.

---

## 4. Cost

**Rates** (all per-second; us-east-1 where relevant):

| | vCPU-hr | GB-hr | Minimum | Notes |
|---|---|---|---|---|
| AWS Lambda MicroVMs | **$0.0997** | **$0.0132** | per-second | + snapshot read ~$0.00155/GB/launch, image storage $0.08/GB-mo. **Premium vCPU rate.** |
| Northflank **managed** | **$0.01667** | **$0.00833** | **none** | + egress $0.06/GB (ingress free), storage $0.15/GB-mo |
| Northflank **BYOC** (platform fee) | **$0.01389** | **$0.00139** | none | **+ your own EC2 bill** (no markup; use spot/RIs) |

**Worked cost — one 3-minute (180 s) job:**

| Config | AWS Lambda MicroVMs | Northflank managed | Northflank BYOC (fee only, + EC2) |
|---|---|---|---|
| 1 vCPU / 2 GB | **$0.00631** | **$0.00167** | $0.00083 + EC2 |
| 2 vCPU / 4 GB | **$0.01261** | **$0.00333** | $0.00167 + EC2 |

**At scale (1 vCPU / 2 GB):**

| Executions/mo | AWS Lambda MicroVMs | Northflank managed | Northflank BYOC (fee only) |
|---|---|---|---|
| 1,000 | $6.31 | $1.67 | $0.83 + EC2 |
| 100,000 | $631 | $167 | $83 + EC2 |
| 1,000,000 | $6,305 | $1,667 | $833 + EC2 |

- **Northflank managed ≈ 3.8× cheaper** than Lambda MicroVMs on compute, driven almost entirely by
  Lambda MicroVMs' premium `$0.0997/vCPU-hr`. **BYOC** is cheaper still on the fee, and with EC2
  **spot** can undercut everything — at the cost of operating capacity.
- Both bill cold-start wall-clock (AWS bills the ~2–2.9 s boot; Northflank bills its provisioning) —
  add a small margin.
- **At Avlo's pre-production scale the absolute difference is pennies** (1k execs/mo = $6 vs $2). The
  cost case only becomes material at **100k+ execs/mo**. Don't switch *for cost* until volume is real.

⚠️ **Caveats:** Lambda MicroVMs pricing is **8 days old** and may be introductory/subject to change
(the repo's verified read of snapshot I/O — `$0.0038`/GB write, `$0.00155`/GB read — differs from some
public summaries quoting `$0.02`/GB; immaterial to you since you don't suspend). Northflank's
**build-minute** pricing could not be verified — **pre-build your image** to avoid per-run build cost.

---

## 5. Reliability, limits, and vendor maturity

**Strengths [measured]:** best independently-benchmarked burst concurrency of any 2026 sandbox
provider (100k/24 s, 0 failures); multi-runtime isolation; unmodified OCI containers + mature BYOC
(lower lock-in than E2B/Modal); sub-second starts corroborated by third-party data.

**Real gotchas, ranked for your use case:**
1. **Default API rate limit: 1000 req/hr.** A high-churn create/poll/destroy loop blows through this;
   raising it needs a support email (and support responsiveness is *inconsistent*). **[measured]**
2. **Recurring "can't create new resources in region" outages** (London, 2025–2026: e.g. two
   incidents on 2026-05-13). That's the **exact hot path** a create-on-demand executor depends on —
   plan multi-region / BYOC fallback. **[measured]**
3. **No dedicated sandbox SDK / no Python SDK** — you orchestrate via the general REST API (similar
   glue to what you already built on AWS; Northflank itself concedes E2B/Modal/Daytona have cleaner
   per-execution DX). **[measured / self-admitted]**
4. **Small-vendor risk** — ~$24.9 M raised, ~19–29 people, ~$2 M ARR; 68+ outages in 4 years incl. a
   self-inflicted 2025 DB-migration cascade. Well-funded, but a startup bet, not a hyperscaler. **[measured]**
5. **Operational papercuts** — inconsistent support, "old documentation," credit-card-required free
   tier. **[reported]**
6. **No independent production testimony** of someone running a per-execution AI sandbox on Northflank
   and reporting what bit them — the capability is benchmark-proven, the lived-prod-experience is scarce.

Versus AWS: you trade hyperscaler reliability, IAM/CloudTrail/VPC maturity, and an 8-day-old-but-
AWS-backed product for cost + scale. AWS's own youth here is real too (8 days GA, 5 regions, ARM64-only).

---

## 6. Honest pros / cons

### Northflank — pros
- **~3.8× cheaper** compute than Lambda MicroVMs; per-second, no minimum; **BYOC cheaper still**.
- **Burst provisioning at a scale AWS structurally can't match** under the 5/s `RunMicrovm` cap.
- Sub-second container-ready, independently verified.
- **Same class of microVM isolation** (Kata + Firecracker/CLH) when configured right.
- **BYOC**: untrusted code in *your* VPC, your KMS, no compute markup, multi-cloud.
- Low workload lock-in (standard OCI images).

### Northflank — cons
- **No memory snapshot** → heavy Python import paid live on each fresh sandbox (warm pool = idle cost).
- **Isolation is opt-in & footgunnable** (must be Sandboxes + Kata, not a default container).
- **1000 req/hr** default API cap; **region-create outages**; **small-vendor** risk.
- No turnkey/Python sandbox SDK; you build the lifecycle yourself.
- Unaudited escape posture; heavy marketing vs. thin independent prod evidence.

### AWS Lambda MicroVMs — pros
- **Free warm-import** via build snapshot → fast, predictable heavy-stack first-touch on every cold VM.
- Hyperscaler reliability, IAM/CloudTrail/VPC, on-label for untrusted code, **8 hr** lifetimes.
- Native suspend/resume + idle policy (even if unused).
- **You've already built and measured it** — it meets the <2 s gate.

### AWS Lambda MicroVMs — cons
- **~3.8× more expensive** compute (premium vCPU rate).
- **5 `RunMicrovm`/sec/account/region hard cap** — a real ceiling for spiky concurrent load.
- **8 days old**, 5 regions, **ARM64-only**, pricing may shift; AWS lock-in.
- Cold-create ~2–2.9 s bound by AWS endpoint routing (outside your control).

---

## 7. Overall fit & recommendation

For **ephemeral, multi-tenant, untrusted Python with a keep-alive-2–3-min lifecycle**, Northflank is a
**legitimate option, not hype** — but the case rests on **cost** and **burst-provisioning headroom**,
not on a capability the AWS path lacks. On the axes you asked about:

- **Startup performance:** A wash-to-slight-AWS-edge for the heavy data-viz stack once you account for
  live import (Northflank's fast container-ready is partly eaten by cold imports AWS pre-warms for
  free). Northflank wins decisively on **burst create rate**.
- **Snapshotting:** Irrelevant to your throwaway model on both sides — but it's *why* Northflank can't
  match AWS's free warm-start.
- **Overall fit:** Northflank fits, with caveats. The strongest version of the Northflank case for you
  is **BYOC-on-AWS**: Kata + Firecracker isolation **in your own VPC**, per-second billing, **no 5/s
  ceiling** (it's their K8s scheduler, not the Lambda MicroVM API), EC2-list/spot compute + a small
  platform fee. That keeps AWS-native data residency while buying scale + cost — at the price of
  operating capacity and depending on their control plane (and its region-create incidents).

**Pragmatic call:** Your AWS path already works and clears the gate. Treat Northflank as a **cost +
scale optimization to validate by benchmark**, not a default swap. The deciding questions are
empirical: (a) does cold first-touch with your *real* heavy image clear your latency bar without a
warm pool? (b) does your concurrency actually hit the 5/s AWS wall? (c) is BYOC's all-in cost (with
spot) worth the second implementation + vendor risk?

---

## 8. If you benchmark Northflank — measure these (not `node -v`)

1. **Cold first-touch with your actual `sci` image** (pandas + seaborn), fresh sandbox, *running real
   user code that imports + renders a PNG* — the number that matters, and the one no public benchmark
   covers. Compare against this repo's ~2–2.9 s cold-create.
2. **Warm fork-server in-session:** replicate the manager + pre-forked-child design from this repo
   inside a Northflank sandbox; measure first-exec (cold import) vs. subsequent forks over a 2–3 min
   session.
3. **Burst create throughput** at your expected peak concurrency, and **confirm the API rate-limit
   raise** with support *before* trusting it. This is where Northflank should structurally beat AWS's
   5/s cap.
4. **BYOC-on-AWS** path specifically: Kata+Firecracker in your VPC; measure start latency, all-in cost
   with spot, and operational overhead vs. managed.
5. **First-image-pull-on-cold-node** tail latency, and **sustained reliability** over days (watch for
   the region-create failure mode).
6. **Egress reality:** confirm PNG result sizes × volume against the `$0.06/GB` egress (negligible for
   small PNGs, worth checking at scale).

---

## Sources

**AWS Lambda MicroVMs** — [AWS launch blog](https://aws.amazon.com/blogs/aws/run-isolated-sandboxes-with-full-lifecycle-control-aws-lambda-introduces-microvms/) ·
[product page](https://aws.amazon.com/lambda/lambda-microvms/) ·
[docs](https://docs.aws.amazon.com/lambda/latest/dg/lambda-microvms-guide.html) ·
[The Register](https://www.theregister.com/devops/2026/06/23/aws-debuts-lambda-microvms-with-up-to-8-hours-runtime/) ·
[InfoQ](https://www.infoq.com/news/2026/06/aws-lambda-microvms/) ·
[theburningmonk](https://theburningmonk.com/2026/06/what-you-need-to-know-about-lambda-microvms/) ·
plus this repo's measured numbers (`README.md`) and verified pricing (`docs/API-FACTS.md`).

**Northflank isolation/security** — [sandboxes-on-kubernetes](https://northflank.com/blog/sandboxes-on-kubernetes) ·
[how-to-run-untrusted-code-on-kubernetes](https://northflank.com/blog/how-to-run-untrusted-code-on-kubernetes) ·
[kata-vs-gvisor](https://northflank.com/blog/kata-containers-vs-gvisor) ·
[kata-vs-firecracker-vs-gvisor](https://northflank.com/blog/kata-containers-vs-firecracker-vs-gvisor) ·
[product/sandboxes](https://northflank.com/product/sandboxes) ·
[Sandboxes docs](https://northflank.com/docs/v1/application/sandboxes/sandboxes-on-northflank) ·
[BYOC](https://northflank.com/product/bring-your-own-cloud) · [security](https://northflank.com/security) ·
independent: [rywalker.com/research/northflank](https://rywalker.com/research/northflank).

**Northflank startup/scale** — [ComputeSDK leaderboard](https://www.computesdk.com/benchmarks/sandboxes/northflank/) ·
[ComputeSDK Scale Invitational](https://platform.computesdk.com/scale-invitational/northflank) ·
[methodology](https://www.computesdk.com/blog/scale-invitational-update/) ·
[secure-sandbox-in-seconds tutorial](https://northflank.com/blog/how-to-spin-up-a-secure-code-sandbox-and-microvm-in-seconds-with-northflank-firecracker-gvisor-kata-clh) ·
[ephemeral-execution-environments](https://northflank.com/blog/ephemeral-execution-environments-ai-agents) ·
classic-path estimate: [alexfazio gist](https://gist.github.com/alexfazio/dcf2f253d346d8ed2702935b57184582).

**Northflank snapshots/persistence** — [add-a-volume](https://northflank.com/docs/v1/application/databases-and-persistence/add-a-volume) ·
[backup-restore](https://northflank.com/docs/v1/application/databases-and-persistence/backup-restore-and-import-data) ·
[best-persistent-sandbox-platforms](https://northflank.com/blog/best-persistent-sandbox-platforms).

**Northflank pricing** — [pricing](https://northflank.com/pricing) ·
[billing docs](https://northflank.com/docs/v1/application/billing/pricing-on-northflank) ·
[Lambda-MicroVMs-vs-Northflank pricing](https://northflank.com/blog/aws-lambda-microvms-vs-northflank-pricing) ·
[AI-sandbox-pricing](https://northflank.com/blog/ai-sandbox-pricing) ·
[AWS Lambda pricing](https://aws.amazon.com/lambda/pricing/) · [AWS Fargate pricing](https://aws.amazon.com/fargate/pricing/).

**Northflank maturity/reliability** — [VentureBeat (funding)](https://venturebeat.com/ai/exclusive-northflank-scores-22-3-million-to-make-cloud-infrastructure-less-of-a-nightmare-for-developers) ·
[StatusGator](https://statusgator.com/services/northflank) ·
[status postmortem](https://status.northflank.com/cmay5h4pg0052zbome4c6m5q6) ·
[API docs (rate limit)](https://northflank.com/docs/v1/api/use-the-api) ·
[HN](https://news.ycombinator.com/item?id=46917340) · [G2](https://www.g2.com/products/northflank/reviews).

> Evidence-quality note: Northflank's cold-start/creation latencies and "2M microVMs/month" are
> vendor-claimed; the **ComputeSDK** numbers and **company/incident** facts are independent/primary.
> Isolation *architecture* is verifiable and standard; its *implementation escape posture* is not
> publicly audited. Lambda MicroVMs pricing is 8 days post-GA and may change.
