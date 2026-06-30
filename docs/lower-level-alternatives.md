# Cheaper, lower-level alternatives to AWS Lambda MicroVMs

> Research note (2026-06-30). Goal: a backend for **untrusted, multi-tenant Python** (heavy
> data-viz: numpy + pandas + matplotlib + seaborn) that spins up a sandbox, runs **≤2–3 min**, then
> **destroys** it. Frequent create/destroy, short bursts, **no persistent state** (so suspend/resume
> for *context* is unneeded). Lambda MicroVMs works but is pricey (~$0.0997/vCPU-hr). Seeking a
> **cheaper, lower-level** path.
>
> **Hard requirements (the scoring rubric):** (1) cold start to running-Python **<2.5s** *with the
> heavy imports*; (2) cheap while hot; (3) frequent create/destroy + burst; (4) **fixed monthly cost
> <$20 or ELIMINATED**; (5) genuine untrusted isolation; (6) acceptable ops. Every number below is
> from a dedicated web-research pass; claims tagged **[measured]** / **[vendor-claimed]** / **[est.]**.

---

## The one insight that organizes everything

Your three hard constraints **interact**, and the interaction picks the architecture:

- **<2.5s cold *with heavy imports*** forces a **warm-import mechanism** — a memory snapshot/restore
  or a kept-warm instance. Plain scale-to-zero containers eat the **~1–3s live import** of
  numpy/pandas/matplotlib/seaborn and miss the bar. This is the same lesson as the Northflank note:
  the import is the tax, and only a snapshot (or a warm pool) pays it down.
- **Genuine untrusted isolation** forces a **microVM (Firecracker/Kata)** or **gVisor**.
- **<$20/mo fixed** means you generally **cannot own the isolation host yourself if it needs KVM** —
  real `/dev/kvm` bare metal starts around **€38/mo**; cheap cloud VMs don't expose nested virt.

**Therefore: under a hard <$20/mo fixed cap, RENT the Firecracker host** (Cloudflare / Fly / Lambda /
E2B amortize the bare metal across many tenants) **rather than OWN it.** Self-hosting Firecracker only
wins on per-job cost once you have sustained volume *and* appetite for the heaviest ops — and even
then, **gVisor (which needs no KVM)** is the cheaper-to-own path if you accept shared-kernel isolation
and low per-box concurrency.

---

## Ranked shortlist (KEEP) — verified numbers

| Option | Fixed / mo | Per 3-min job | Cold start (heavy imports) | Isolation | Scale-to-zero | Ops |
|---|---|---|---|---|---|---|
| **Fly.io Machines** | ~$4.50 (pool storage) | **~$0.001–0.002** | ~few hundred ms suspend/resume (≤2GB) | **Firecracker microVM** | yes | Medium |
| **Cloudflare Containers** | **$5** (Workers Paid) | ~$0.006 | ~1–3s; warm via `sleepAfter` | **Firecracker microVM**¹ | yes | **Low** (your stack) |
| **Blaxel** | **$0** | ~$0.004–0.008 | **<25ms** standby resume / **2.9s** naive ❌ | **Firecracker microVM** | yes (standby) | Low (SDK) — *seed-stage* |
| **Lambda + SnapStart (Py)** | **$0** | ~$0.005 | **~0.5–0.6s** (snapshot) | Firecracker — *SnapStart ⊥ tenant-isolation* | yes | Low |
| **GKE Standard (self-managed)** | **~$13–15** (n2d Spot) | **~$0.001** | <2.5s *only* w/ warm fork-server pod | gVisor (below Firecracker) | no (warm node) | **High** (own the cluster) |
| **gVisor on a cheap VM + C/R** | ~$12 (t4g.small) | **~$0** marginal | **sub-second** (`runsc restore`) | gVisor (shared-kernel emulation) | no (box 24/7) | High |
| **E2B free tier** | **$0** (+$100 credit) | ~$0.004 | ~150–200ms (FC snapshot) | **Firecracker microVM** | yes | **Lowest** (SDK) |
| **Cloud Run Jobs** | **$0** | ~$0.007–0.015 | **~3–6s** ❌ (no snapshot) | gen2 microVM | yes | Low |
| **Self-host Firecracker (metal)** | **~€38** ❌>$20 | ~$0 marginal | ~150ms (snapshot restore) | **Firecracker microVM** | n/a | **Highest** |

¹ Cloudflare Containers' isolation is reported as **Firecracker microVM** (third-party writeups); one source frames it as gVisor-class — confirm against Cloudflare's own docs.

All of these beat Lambda MicroVMs (~$0.0997/vCPU-hr ⇒ ~$0.005–0.013/job) on cost. The discriminators are
**cold-start-with-heavy-imports**, **fixed cost**, and **ops**.

> **Warm-mechanism taxonomy** (the thing that actually clears <2.5s): two families. **Snapshot-park-and-restore**
> — park at ~$0 compute, restore a warm interpreter in ms: Fly suspend/resume, Blaxel standby snapshot, Lambda
> SnapStart, self-hosted Firecracker, gVisor checkpoint/restore. **Keep-warm-running** — no memory snapshot, you
> pay compute to hold it warm: Cloudflare `sleepAfter`, a GKE warm fork-server pod. The first family is more
> cost-efficient when there are idle gaps between jobs; the second is simpler within an active session.

---

## Per-option detail

### 1. Cloudflare Containers — TOP PICK (you're already on Cloudflare)
- **Isolation:** each container instance is **its own Firecracker microVM (KVM)** — same class as Lambda
  MicroVMs, safe for adversarial code; ephemeral disk, fresh per start. **[vendor-claimed, corroborated]**
- **Cold start:** docs say **~1–3s** depending on image size; Cloudflare pre-schedules instances and
  pre-fetches images globally. There is **no memory snapshot** — so for the heavy import you lean on
  **`sleepAfter`** (keep the microVM alive between requests so imports stay resident) or a warm pool,
  not a snapshot. Within your keep-alive-2–3min session that's a natural fit: import once, reuse warm.
- **Cost:** vCPU **$0.000020/s**, mem **$0.0000025/GiB-s** → a 3-min job ≈ **$0.006** (~½ Lambda MicroVMs);
  free allowance 375 vCPU-min + 25 GiB-hr/mo. **Only fixed cost is the $5/mo Workers Paid plan** (Containers
  are Paid-only) — under $20. **[measured]**
- **Fit:** wires into your existing Workers+R2 via a Durable Object → `container.start`. **Lowest new
  infra of any option.** Caveats: **amd64-only**, **max 4 vCPU / 12 GiB / 20 GB disk**, 50 GB image
  storage/account — confirm 12 GiB covers worst-case seaborn renders, and measure a true cold boot.
- **Verdict: KEEP — best overall fit for Avlo.**

### 2. Fly.io Machines — best snapshot-warm-import that you don't operate
- **Isolation:** every Machine is a real **Firecracker microVM**; **Fly Sprites** (Jan 2026) is their
  managed untrusted-code sandbox built on it. **[vendor-claimed, corroborated]**
- **Warm imports:** **suspend/resume = a Firecracker memory snapshot** — resume in **~few hundred ms**
  with imports already in RAM. **Capped at ≤2GB machine memory**; a freshly-imported numpy/pandas/
  matplotlib/seaborn process is ~300–600MB RSS, so 2GB fits. (Plain *stop* → cold re-import ~4–6s, blows
  the bar — use suspend, not stop.) **[vendor docs; preview-grade]**
- **Cost:** no mandatory platform fee; **idle = storage only (~$0.15/GB-mo)** → a 10-machine suspended
  pool ≈ **$4.50/mo**. Per 3-min job ≈ **$0.001–0.002** (shared-cpu). **[measured]**
- **Churn:** *create* is rate-limited ~1–3/s per app; *start* is per-machine and scales — so **pre-warm
  a suspended pool and `start` per request**, refill asynchronously.
- **Caveats:** suspend is preview (snapshots don't survive deploys/host migrations), occasional stuck
  machines, rootfs IOPS-limited (2000 IOPS) — tolerable for stateless compute. Not your existing stack.
- **Verdict: KEEP — the cleanest way to get snapshot-warm-imports without owning metal.**

### 3. AWS Lambda classic + SnapStart for Python — cheapest zero-ops serverless, one hard trade
- **Warm imports:** SnapStart (Python 3.12+, GA late-2024; arm64 2025) takes a **Firecracker snapshot of
  fully-initialized memory** after INIT, so module-scope imports are baked in → cold start **~0.5–0.6s**
  (measured pandas+numpy **2929ms→473ms**). Restore ~30–280ms, sub-second even at 2–4GB. **[measured]**
- **Cost:** arm64 $0.0000133/GB-s + tiny restore/cache fees → **~$0.005/job, $0 fixed**. **[measured]**
- **THE CATCH — isolation lever:** classic Lambda **reuses** an execution environment across sequential
  invocations (user B can land in user A's warm microVM). AWS's new **tenant-isolation mode** (re:Invent
  2025) fixes this (never reuse an env across tenants) — **but it is incompatible with SnapStart.** So you
  pick **fast warm imports (SnapStart)** *or* **guaranteed per-tenant fresh envs (tenant isolation,
  accept ~1–3s cold imports)**, not both. With SnapStart you'd need hard env-recycling (reserved
  concurrency=1 + self-terminate, wipe /tmp) as a partial mitigation. 512MB /tmp cap (fine for in-memory
  PNG). **[measured — AWS docs explicit on the incompatibility]**
- **Verdict: KEEP — cheapest serverless, but choose the isolation lever deliberately.**

### 4. gVisor on one cheap VM + checkpoint/restore — the under-$20 self-host compromise
- **Warm imports without KVM:** gVisor's **checkpoint/restore** turns the thousands of import syscalls
  into ~one file load. Pattern: boot once, import the stack, `runsc checkpoint`, then `runsc restore` per
  job → **sub-second** time-to-first-instruction. Runs on gVisor's **systrap** platform → **no `/dev/kvm`
  needed**, so any cheap VM works. **[vendor docs; mechanism high-confidence, exact ms medium]**
- **Cost:** **t4g.small (2 vCPU/2GB) ≈ $12.26/mo**, **~$0 marginal/job**. **[measured]**
- **Isolation:** gVisor Sentry (the GKE Sandbox engine) is a genuine untrusted boundary — but it's
  **shared-kernel emulation on a single box**, so add per-sandbox cgroups/seccomp/egress caps. numpy is
  ~native under gVisor; the syscall/file-I/O-heavy import + matplotlib paths are gVisor's worst axis
  (mitigated by the warm-checkpoint approach). **[measured]**
- **Limits:** **no true scale-to-zero** (box runs 24/7), **~3–5 concurrent heavy-viz sandboxes per
  small box** (RAM-bound) — add boxes to scale. Highest ops among the rentals.
- **Verdict: KEEP — cheapest absolute fixed cost with real isolation, if you build the pipeline and
  volume is low.**

### 5. E2B free tier — the zero-effort low-volume winner
- Purpose-built to run untrusted code in **Firecracker microVMs** (snapshot restore **~150–200ms**), 3-line
  SDK create→run→destroy. **Hobby = $0 fixed + $100 one-time credit**, 20 concurrent sandboxes. ~$0.004/job.
  Managed (not lower-level), but at low volume the free credit **undercuts everything**. **Verdict: KEEP as
  baseline/overflow.** (Pro is $150/mo → eliminated as a committed tier; the free tier stays.)

### 6. Cloud Run Jobs — $0 idle + huge free tier, but fails <2.5s cold
- **Jobs** = a fresh **gen2 microVM** container per execution (clean per-tenant boundary), **$0 idle**,
  ~**25,000 free 3-min jobs/mo**, ~$0.007–0.015/job, low ops. **But no snapshot/SnapStart**, so heavy-import
  cold start is **~3–6s** — fails the <2.5s rule, and the only fix (min-instances) is **~$65/mo** → breaks
  the $20 rule. **Verdict: KEEP only if you relax <2.5s** (e.g. a "running your code…" spinner is fine) — then
  it's arguably the cheapest low-effort option at low volume.

### 7. Self-hosted Firecracker + snapshot-restore — the technical holy grail, blocked by the KVM-host floor
- **Best mechanism for your need:** build one snapshot with the libs pre-imported, **restore a fresh
  microVM per job in ~150ms** (E2B runs exactly this in prod), ~$0 marginal/job, ~30–60 concurrent on 32GB
  via COW page-sharing, hundreds of restores/sec. Genuine Firecracker+jailer isolation. **[measured]**
- **The blocker:** **no host under $20/mo exposes real `/dev/kvm`.** Cheap cloud VMs (Hetzner CX/CAX,
  etc.) disable nested virt; the **PVM** "Firecracker without KVM" hack is experimental (custom-patched
  host+guest kernels, ~75% overhead, per-instance-type fragility) — a maintenance trap for untrusted
  multi-tenant. Real KVM = bare metal: **Hetzner auction ~€38/mo**, OVH SoYouStart ~$33–40, GCE nested-virt
  (N1 only) ~$50+. The *only* sub-$20 real-KVM box is a **cramped 4GB Atom Kimsufi (~$11–15)** → ~2–4
  microVMs, weak numpy. **[measured]**
- **Ops:** heaviest by far — snapshot-build pipeline, per-microVM tap networking + NAT, vsock agent, reaping,
  jailer hardening, RNG re-seed + unique MAC/IP per restore (snapshot entropy reuse), kernel-CVE patching.
  Tooling: `firecracker-go-sdk`, jailer, `firecracker-containerd`, **Flintlock** (Ignite's successor); study
  **E2B's open infra**. No lock-in.
- **Verdict: KEEP only at sustained volume + ops appetite, and only if you bend the $20 rule to ~€38/mo.
  Under a strict $20 cap with real concurrency: ELIMINATE** (the gVisor-on-$12-VM path is the under-$20
  self-host alternative).

---

### 8. GKE Standard, self-managed warm pool — you control everything
- **The warm-option cost (the headline):** control plane **$0** — the **$74.40/mo free credit** zeroes the
  $73/mo fee for **one zonal** Standard cluster (regional or a 2nd cluster is not covered). The warm node is the
  fixed cost and **Spot is the lever** — and **n2d discounts ~76% vs e2's ~47%**, so **n2d-standard-2 Spot ≈
  $14.75/mo** (full 2 vCPU/8GB) beats e2-medium Spot (~$12.85, 2sh/4GB) on price *and* specs. e2-small Spot
  ~$6.42 is cheapest but 2GB risks OOM on the heavy stack. **So a credible warm option ≈ $13–15/mo, total fixed
  <$20.** **[measured]**
- **The catch — warm node ≠ <2.5s:** fresh-pod-per-job is **~10–15s** even with the image pre-pulled. You clear
  <2.5s **only** with a **warm pod running a pre-imported Python fork-server** (`fork()` per job → tens of ms) —
  i.e. **the exact warm fork-server already in this repo's in-VM manager, lifted to a pod**. (gVisor checkpoint/
  restore is not a reliable GKE-managed path today; use the forkserver.) **[measured/inference]**
- **Isolation:** GKE Sandbox = **gVisor** (`--sandbox type=gvisor`; COS+containerd; ≥2 node pools; recommended
  n2-class) — a genuine untrusted boundary but **a notch below your Firecracker baseline**; driver/CSI gaps. **[measured]**
- **Spot/burst:** a preempted Spot warm node (~30s notice, no SLA) drops the warm guarantee until replaced
  (minute-plus cold) — add a 1× on-demand floor (~$12/mo) + Spot burst, ≥2 nodes, a PDB. Burst beyond warm pods
  provisions a new node in tens of seconds–minutes (cold). Marginal job **~$0.001** (≈10× cheaper than Lambda hot).
- **Ops:** highest-touch managed option (node pools, gVisor, forkserver lifecycle + per-tenant teardown + memory
  caps, PDB, autoscaler, image pre-pull, upgrades, network policy). "Fleets" = node pools; **GKE Fleet** =
  multi-cluster management, not a cost lever.
- **Verdict: KEEP (conditional)** — the cheapest *controllable* warm path at **~$13–15/mo** *if* you build/operate
  the forkserver pod and accept gVisor (< Firecracker) + real K8s ops. **Autopilot-from-zero stays eliminated.**

### 9. Blaxel — best turnkey warm-snapshot resume, but seed-stage
- **What/isolation:** AI-agent infra startup (founded 2024, $7.3M seed, YC S2025; sandbox runtime repo ~22★ but
  active). Sandboxes run on a **custom bare-metal Firecracker** ("Mark 3.1") — genuine microVM, same isolation
  class as Lambda MicroVMs. **$0 mandatory fixed cost** (pricing "tiers" are credit-top-up thresholds, not
  subscriptions; Tier 0 free = 10 concurrent + up to $200 credit). Managed-only, **no BYOC**. Python/TS/Go SDKs. **[vendor + independent]**
- **The snapshot answer (your question):** **Yes — but it's a one-directional *standby* snapshot, not a
  fork-from-base primitive.** On idle (~5–15s) it snapshots memory+disk+**running processes**; resume restores the
  live process in **<25ms**. There is **no "create N fresh sandboxes from one warm snapshot" API**, and custom base
  *images* bake in *installed* packages, **not imported-into-memory** state. So a **naive fresh create ≈ 2.9s**
  (independent benchmark) **+ live imports ≈ 4–6s → fails <2.5s**. You beat the bar **only** by importing once,
  letting the sandbox go to standby (snapshot captures the warm interpreter), then **resuming per job (<25ms)** —
  parked at ~$0 compute ($0.20/GB-mo snapshot storage). **[independent benchmark + vendor docs]**
- **Cost:** RAM-based, CPU bundled — **$0.0000115/GB-RAM-s** → 2GB/~1vCPU ≈ **$0.0041/3-min job**, 4GB/~2vCPU ≈
  **$0.0083**. **~2–4× cheaper per job than Lambda MicroVMs**, ≈ Cloudflare on per-job (cheaper on fixed: $0 vs $5),
  but **Fly.io undercuts it ~3–5×**. **[measured]**
- **Verdict: KEEP (top-3 turnkey)** — best out-of-the-box warm-resume (<25ms) + Firecracker + $0 fixed + cheaper
  than your Lambda. **Caveats:** must pre-warm (naive create fails <2.5s), and it's a **seed-stage vendor** (1-yr-old,
  thin track record) — fine for a non-critical isolated subsystem, riskier as core infra. Their "sub-25ms cold start"
  headline = **resume-from-standby only**, not a fresh create.

## ELIMINATE (noise / disqualified)

| Option | Disqualifier |
|---|---|
| **AWS EKS** | $0.10/hr control-plane ≈ **$73/mo fixed**. |
| **AWS Fargate** | Task launch **~30–90s** (image-pull-bound) ≫ 2.5s; warm-pool workaround **~$28–36/mo** breaks $20. |
| **Self-Firecracker on AWS EC2** | Needs `*.metal` (no small metal; huge fixed) — or fails <2.5s scaling a normal instance from zero. |
| **PVM (Firecracker w/o KVM)** | Experimental, custom-patched kernels, ~75% overhead, fragile per instance type — unsafe to depend on. |
| **GKE Autopilot (from zero)** | Node provisioning is tens of seconds → fails <2.5s; Autopilot can't hold a warm node cheaply. **(GKE *Standard*, self-managed, is a conditional KEEP — see §8.)** |
| **Railway** | No scale-to-zero; 24/7 container ≈ $30/mo for bursty 3-min jobs. |
| **Render** | Free tier 30–60s cold start; paid removes scale-to-zero (~$26/mo to be useful). |
| **Civo (managed k3s)** | Always-on worker nodes (~$10+/mo, no scale-to-zero) + shared-kernel pods (wrong isolation). |
| **Koyeb** | Free instance too thin (1 vCPU/512MB, region-locked); paid offers no isolation/price edge. |
| **DigitalOcean Functions / App Platform** | Functions: no heavy-lib/custom-Docker + no clear timeout; App Platform: shared-kernel, long-lived-service oriented. |
| **Daytona** | Fast + $200 credit, but **shared-kernel containers** — weaker boundary for adversarial code. |
| **Modal / E2B / Daytona paid base tiers** | $150–250/mo base ≫ $20 (their **free tiers** are kept above). |

---

## Recommendation

Decision hinges on **expected concurrency/volume** (not yet specified) and how hard the **<2.5s** bar is.

1. **Default for Avlo → Cloudflare Containers.** Firecracker isolation, **$5/mo**, ~½ Lambda cost, and it
   collapses into your existing Workers+R2 stack with the least new infrastructure. Use `sleepAfter` to keep
   a per-session microVM warm so the heavy import is paid once per session. **Prototype + measure the true
   cold boot of your sci-image and confirm 12 GiB headroom.**
2. **If you want the snapshot-warm-import guarantee and don't mind leaving Cloudflare → Fly.io Machines**
   with a **suspended ≤2GB pool** (warm imports in a few hundred ms, ~$4.50/mo idle). This most directly
   replicates the one thing you liked about Lambda MicroVMs.
   - *Best turnkey warm-resume:* **Blaxel** (<25ms standby-snapshot resume, Firecracker, $0 fixed, ~$0.004–0.008/job)
     — if you accept a seed-stage vendor and pre-warm. *Full control at ~$13–15/mo:* **GKE Standard self-managed**
     (n2d Spot warm node + free control plane) running your existing warm fork-server as a pod — gVisor isolation,
     real K8s ops.
3. **Cheapest at low volume / zero effort → E2B free tier** (Firecracker, $0 + $100 credit), or **Cloud Run
   Jobs** if you can tolerate a 3–6s cold spinner (then its free tier covers ~25k jobs/mo).
4. **Self-host only at sustained volume + ops appetite.** Firecracker-on-bare-metal (~€38/mo) is the cost
   floor per job but breaks the strict $20 rule and is the heaviest ops; **gVisor-on-a-$12-VM + checkpoint/
   restore** is the under-$20 self-host compromise (no KVM), at the price of shared-kernel isolation and
   ~3–5 concurrent/box.

**What to prototype (measure, don't trust the brochure):** for the top 1–2, run your **real sci-image**
(numpy+pandas+matplotlib+seaborn, render a PNG) and measure **true cold first-touch** and **warm reuse** —
the public benchmarks all use trivial commands and hide the import cost that dominates your workload.

---

## Sources
Fly.io: [pricing](https://fly.io/docs/about/pricing/) · [suspend/resume](https://fly.io/docs/reference/suspend-resume/) · [Machines API](https://fly.io/docs/machines/api/working-with-machines-api/) · [Sprites (Simon Willison)](https://simonwillison.net/2026/Jan/9/sprites-dev/).
Cloudflare: [Containers pricing](https://developers.cloudflare.com/containers/pricing/) · [limits](https://developers.cloudflare.com/containers/platform-details/limits/) · [architecture (Firecracker)](https://developers.cloudflare.com/containers/platform-details/architecture/) · [Ernest Chiang writeup](https://www.ernestchiang.com/en/posts/2025/firecracker-powered-containers-arrive-on-cloudflare/).
Cloud Run: [pricing](https://cloud.google.com/run/pricing) · [security/isolation](https://docs.cloud.google.com/run/docs/securing/security) · [Jobs+gen2 GA](https://cloud.google.com/blog/products/serverless/cloud-run-jobs-and-second-generation-execution-environment-ga) · [AI cold starts (3–5s Python)](https://cloud.google.com/blog/topics/developers-practitioners/a-guide-to-ai-cold-starts-on-cloud-run) · [untrusted-code reference](https://github.com/GoogleCloudPlatform/cloud-run-sandbox).
GKE: [pricing](https://cloud.google.com/kubernetes-engine/pricing) · [GKE Sandbox (gVisor)](https://docs.cloud.google.com/kubernetes-engine/docs/concepts/sandbox-pods) · [Autopilot overview](https://docs.cloud.google.com/kubernetes-engine/docs/concepts/autopilot-overview).
Lambda: [SnapStart docs](https://docs.aws.amazon.com/lambda/latest/dg/snapstart.html) · [under the hood](https://aws.amazon.com/blogs/compute/under-the-hood-how-aws-lambda-snapstart-optimizes-function-startup-latency/) · [tenant isolation mode](https://docs.aws.amazon.com/lambda/latest/dg/tenant-isolation.html) · [SnapStart Python benchmark](https://dev.to/mate32/my-aws-lambda-runs-faster-than-yours-heres-how-to-optimize-lambda-cold-starts-with-snapstart-4odd).
Fargate: [pricing](https://aws.amazon.com/fargate/pricing/) · [cold-start analysis](https://aws.plainenglish.io/taming-cold-starts-on-aws-fargate-the-architecture-behind-sub-5-second-task-launches-622ebd73b051).
gVisor: [checkpoint/restore](https://gvisor.dev/docs/user_guide/checkpoint_restore/) · [security](https://gvisor.dev/docs/architecture_guide/security/) · [Systrap](https://gvisor.dev/blog/2023/04/28/systrap-release/) · [MAGI (2026)](https://gvisor.dev/blog/2026/04/15/magi-multi-agent-gvisor-isolation/).
Self-host Firecracker: [snapshot support](https://github.com/firecracker-microvm/firecracker/blob/main/docs/snapshotting/snapshot-support.md) · [page faults on resume](https://github.com/firecracker-microvm/firecracker/blob/main/docs/snapshotting/handling-page-faults-on-snapshot-resume.md) · [FC without KVM / PVM (Alex Ellis)](https://blog.alexellis.io/how-to-run-firecracker-without-kvm-on-regular-cloud-vms/) · [E2B breakdown](https://memo.d.foundation/breakdown/e2b) · [Flintlock](https://github.com/liquidmetal-dev/flintlock) · [28ms sandboxes](https://dev.to/adwitiya/how-i-built-sandboxes-that-boot-in-28ms-using-firecracker-snapshots-i0k).
Hosts: [Hetzner June-2026 pricing](https://byteiota.com/hetzner-june-2026-price-shock/) · [Hetzner auction](https://www.hetzner.com/sb/) · [Kimsufi](https://www.kimsufi.com/en/) · [GCE nested virt](https://docs.cloud.google.com/compute/docs/instances/nested-virtualization/overview).
Budget PaaS / sandboxes: [Modal pricing](https://modal.com/pricing) · [E2B pricing](https://e2b.dev/pricing) · [Daytona vs E2B](https://www.zenml.io/blog/e2b-vs-daytona) · [Scaleway serverless](https://www.scaleway.com/en/pricing/serverless/) · [Railway](https://docs.railway.com/pricing) · [Render](https://render.com/pricing) · [Koyeb](https://www.koyeb.com/pricing) · [Civo](https://www.civo.com/pricing).
