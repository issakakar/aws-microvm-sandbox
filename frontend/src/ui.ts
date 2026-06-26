// Pure DOM rendering — no framework dependency.
// Re-called on every state change; preserves the CodeMirror mount.
import type { AppState } from "./main.js";
import type { Variant, Region, Lifecycle, Action, RunRecord, ProvisionerTimings, InvmTimings } from "./types.js";

export interface UICallbacks {
  onVariant: (v: Variant) => void;
  onRegion: (r: Region) => void;
  onLifecycle: (l: Lifecycle) => void;
  onAction: (a: Action) => void;
}

// ── Helpers ────────────────────────────────────────────────────────────────────
function esc(s: string): string {
  return s
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

function btn(
  label: string,
  active: boolean,
  disabled: boolean,
  cls: string,
  dataAttr: string
): string {
  return `<button class="btn ${cls}${active ? " btn--active" : ""}${disabled ? " btn--disabled" : ""}" ${dataAttr} ${disabled ? "disabled" : ""}>${label}</button>`;
}

function fmtMs(ms: number | undefined | null): string {
  if (ms === undefined || ms === null) return "—";
  return ms.toFixed(1) + " ms";
}

function fmtBool(b: boolean | undefined | null): string {
  if (b === undefined || b === null) return "—";
  return b ? "✓ yes" : "✗ no";
}

// ── Timing table ───────────────────────────────────────────────────────────────
function timingTable(
  clientMs: number,
  prov: ProvisionerTimings,
  invm: InvmTimings | null
): string {
  const rows: Array<{ segment: string; value: string; source: string }> = [
    { segment: "Client end-to-end", value: fmtMs(clientMs), source: "browser performance.now()" },
    { segment: "— Lambda cold start", value: fmtBool(prov.lambdaCold), source: "provisioner" },
    { segment: "RunMicrovm call", value: fmtMs(prov.runMicrovmMs), source: "provisioner" },
    { segment: "Auth token mint", value: fmtMs(prov.tokenMintMs), source: "provisioner" },
    { segment: "Token overlap (hidden)", value: fmtMs(prov.tokenOverlapMs), source: "provisioner" },
    { segment: "Exec RTT (held)", value: fmtMs(prov.execRttMs), source: "provisioner" },
    { segment: "First attempt held?", value: fmtBool(prov.firstAttemptHeld), source: "provisioner" },
    { segment: "Exec retries", value: String(prov.execRetries ?? "—"), source: "provisioner" },
    { segment: "Provisioner total", value: fmtMs(prov.totalMs), source: "provisioner Go monotonic" },
  ];

  if (invm) {
    rows.push(
      { segment: "Since /run hook (in-VM)", value: fmtMs(invm.sinceRunHookMs), source: "in-VM CLOCK_MONOTONIC" },
      { segment: "Dispatch", value: fmtMs(invm.dispatchMs), source: "in-VM" },
      { segment: "Fork", value: fmtMs(invm.forkMs), source: "in-VM" },
      { segment: "Pre-fork used?", value: fmtBool(invm.preforkUsed), source: "in-VM" },
      { segment: "User code", value: fmtMs(invm.userCodeMs), source: "in-VM" },
      { segment: "First import touch", value: fmtMs(invm.firstImportTouchMs), source: "in-VM" },
      { segment: "Render (savefig)", value: fmtMs(invm.renderMs), source: "in-VM" },
      { segment: "Serialize", value: fmtMs(invm.serializeMs), source: "in-VM" },
      { segment: "In-VM total", value: fmtMs(invm.totalMs), source: "in-VM CLOCK_MONOTONIC" },
      { segment: "Resumed since last exec?", value: fmtBool(invm.resumedSinceLastExec), source: "in-VM" }
    );
  }

  return `
    <table class="timing-table">
      <thead>
        <tr><th>Segment</th><th>Value</th><th>Source</th></tr>
      </thead>
      <tbody>
        ${rows.map(r => `<tr><td>${esc(r.segment)}</td><td class="mono">${esc(r.value)}</td><td class="dim">${esc(r.source)}</td></tr>`).join("")}
      </tbody>
    </table>`;
}

// ── Run record card ────────────────────────────────────────────────────────────
function runCard(rec: RunRecord, idx: number): string {
  const r = rec.response;
  const isFirst = idx === 0;
  const regimeBadge = `<span class="badge badge--${esc(r.regime)}">${esc(r.regime)}</span>`;
  const stateBadge = `<span class="badge badge--state">${esc(r.state)}</span>`;
  const costBadge = r.costEstimateUsd != null
    ? `<span class="badge badge--cost">$${r.costEstimateUsd.toFixed(6)}</span>`
    : "";

  const header = `
    <div class="run-header">
      <div class="run-meta">
        <span class="run-num">#${idx + 1}</span>
        ${regimeBadge} ${stateBadge} ${costBadge}
        <span class="dim">${esc(rec.request.action)} · ${esc(rec.region)} · ${esc(rec.request.variant)} · ${esc(rec.request.lifecycle)}</span>
      </div>
      <div class="run-id mono dim">${esc(r.microvmId ?? "")}</div>
    </div>`;

  // Error state
  if (!r.ok || r.error) {
    return `
      <div class="run-card run-card--error${isFirst ? " run-card--first" : ""}">
        ${header}
        <div class="run-error">Error: ${esc(r.error ?? "unknown")}</div>
      </div>`;
  }

  const res = r.result;

  const imagePart = res?.imagePngB64
    ? `<div class="figure-box"><img class="figure-img" src="data:image/png;base64,${res.imagePngB64}" alt="plot" /></div>`
    : "";

  const stdoutPart = res?.stdout
    ? `<div class="output-box"><div class="output-label">stdout</div><pre class="output-pre">${esc(res.stdout)}</pre></div>`
    : "";

  const stderrPart = res?.stderr
    ? `<div class="output-box output-box--err"><div class="output-label">stderr</div><pre class="output-pre">${esc(res.stderr)}</pre></div>`
    : "";

  const timings = r.timings
    ? timingTable(rec.clientMs, r.timings.provisioner, r.timings.invm)
    : "";

  return `
    <div class="run-card${isFirst ? " run-card--first" : ""}">
      ${header}
      ${imagePart}
      ${stdoutPart}
      ${stderrPart}
      <details class="timings-details"${isFirst ? " open" : ""}>
        <summary class="timings-summary">Timings</summary>
        ${timings}
      </details>
    </div>`;
}

// ── Main render ────────────────────────────────────────────────────────────────
export function renderUI(state: AppState, cb: UICallbacks): void {
  const shell = document.getElementById("shell");
  if (!shell) return;

  const hasId = !!state.lastMicrovmId;
  const loading = state.loading;

  const variantBtns: Array<{ label: string; v: Variant }> = [
    { label: "Base Python", v: "base" },
    { label: "Matplotlib+NumPy", v: "mpl" },
    { label: "Pandas+Seaborn", v: "sci" },
  ];

  const regionBtns: Array<{ label: string; r: Region }> = [
    { label: "us-east-1", r: "us-east-1" },
    { label: "us-west-2", r: "us-west-2" },
  ];

  const lifecycleBtns: Array<{ label: string; l: Lifecycle }> = [
    { label: "ephemeral", l: "ephemeral" },
    { label: "idle30", l: "idle30" },
    { label: "idle60", l: "idle60" },
    { label: "max5", l: "max5" },
    { label: "max10", l: "max10" },
  ];

  const actionBtns: Array<{ label: string; a: Action; needsId?: boolean; title?: string }> = [
    { label: "Run (cold create)", a: "run", title: "Cold-create a new microVM and execute" },
    { label: "Run again (hot)", a: "reuse", needsId: true, title: "Reuse existing microvmId (hot path)" },
    { label: "Run after resume", a: "reuse", needsId: true, title: "Trigger auto-resume then execute (first suspend, then reuse)" },
    { label: "Suspend now", a: "suspend", needsId: true, title: "Checkpoint the microVM" },
    { label: "Terminate", a: "terminate", needsId: true, title: "Terminate the microVM" },
  ];

  const html = `
    <div class="layout">
      <header class="top-bar">
        <span class="logo">μvm-bench</span>
        <span class="top-bar-sub">Lambda MicroVMs · latency benchmark</span>
        ${state.lastMicrovmId ? `<span class="microvm-pill mono">${esc(state.lastMicrovmId)}</span>` : ""}
      </header>

      <main class="main-grid">
        <!-- Left column: controls + editor -->
        <div class="left-col">

          <!-- Variant selector -->
          <section class="control-section">
            <div class="control-label">Variant</div>
            <div class="btn-group">
              ${variantBtns.map(({ label, v }) =>
                btn(label, state.variant === v, loading, "btn--variant", `data-variant="${v}"`)
              ).join("")}
            </div>
          </section>

          <!-- Region selector -->
          <section class="control-section">
            <div class="control-label">Region</div>
            <div class="btn-group">
              ${regionBtns.map(({ label, r }) =>
                btn(label, state.region === r, loading, "btn--region", `data-region="${r}"`)
              ).join("")}
            </div>
          </section>

          <!-- Lifecycle selector -->
          <section class="control-section">
            <div class="control-label">Lifecycle preset</div>
            <div class="btn-group">
              ${lifecycleBtns.map(({ label, l }) =>
                btn(label, state.lifecycle === l, loading, "btn--lifecycle", `data-lifecycle="${l}"`)
              ).join("")}
            </div>
          </section>

          <!-- Code editor -->
          <section class="control-section editor-section">
            <div class="control-label">Code  <span class="dim">(Python)</span></div>
            <div id="code-editor-mount" class="editor-mount"></div>
          </section>

          <!-- Action buttons -->
          <section class="control-section">
            <div class="control-label">Actions</div>
            <div class="btn-group btn-group--actions">
              ${actionBtns.map(({ label, a, needsId, title }) => {
                const disabled = loading || (!!needsId && !hasId);
                const titleAttr = title ? `title="${esc(title)}"` : "";
                return btn(label, false, disabled, `btn--action btn--action-${a}`, `data-action="${a}" ${titleAttr}`);
              }).join("")}
            </div>
          </section>

          ${state.error ? `<div class="error-banner">${esc(state.error)}</div>` : ""}
          ${loading ? `<div class="loading-banner"><span class="spinner"></span> Running…</div>` : ""}

        </div>

        <!-- Right column: results -->
        <div class="right-col">
          <div class="results-header">Results</div>
          ${state.runs.length === 0
            ? `<div class="no-results">No runs yet. Select a variant, region, lifecycle and click <strong>Run (cold create)</strong>.</div>`
            : state.runs.map((rec, i) => runCard(rec, i)).join("")
          }
        </div>
      </main>
    </div>`;

  shell.innerHTML = html;

  // Re-mount CodeMirror into the placeholder (innerHTML wipes it)
  // Import lazily to avoid circular; main.ts owns the editor instance
  const mountEl = document.getElementById("code-editor-mount");
  if (mountEl) {
    // Signal main.ts to re-attach; we dispatch a custom event
    mountEl.dispatchEvent(new CustomEvent("editor-mount", { bubbles: true }));
  }

  // Attach event listeners
  shell.querySelectorAll("[data-variant]").forEach(el => {
    el.addEventListener("click", () => {
      const v = (el as HTMLElement).dataset["variant"] as Variant;
      if (v) cb.onVariant(v);
    });
  });

  shell.querySelectorAll("[data-region]").forEach(el => {
    el.addEventListener("click", () => {
      const r = (el as HTMLElement).dataset["region"] as Region;
      if (r) cb.onRegion(r);
    });
  });

  shell.querySelectorAll("[data-lifecycle]").forEach(el => {
    el.addEventListener("click", () => {
      const l = (el as HTMLElement).dataset["lifecycle"] as Lifecycle;
      if (l) cb.onLifecycle(l);
    });
  });

  shell.querySelectorAll("[data-action]").forEach(el => {
    el.addEventListener("click", () => {
      const a = (el as HTMLElement).dataset["action"] as Action;
      if (a) cb.onAction(a);
    });
  });
}
