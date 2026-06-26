import "./styles.css";
import { EditorState } from "@codemirror/state";
import {
  EditorView,
  keymap,
  lineNumbers,
  highlightActiveLineGutter,
  highlightSpecialChars,
  drawSelection,
  dropCursor,
  rectangularSelection,
  crosshairCursor,
  highlightActiveLine,
} from "@codemirror/view";
import { defaultKeymap, history, historyKeymap } from "@codemirror/commands";
import { python } from "@codemirror/lang-python";
import { oneDark } from "@codemirror/theme-one-dark";
import {
  foldGutter,
  indentOnInput,
  syntaxHighlighting,
  defaultHighlightStyle,
  bracketMatching,
  foldKeymap,
} from "@codemirror/language";
import { closeBrackets, closeBracketsKeymap } from "@codemirror/autocomplete";
import { searchKeymap, highlightSelectionMatches } from "@codemirror/search";

import { callProvisioner } from "./api.js";
import { SAMPLES } from "./samples.js";
import type {
  Variant,
  Region,
  Lifecycle,
  Action,
  BenchResponse,
  RunRecord,
} from "./types.js";
import { renderUI } from "./ui.js";

// ── Application state ────────────────────────────────────────────────────────
export interface AppState {
  variant: Variant;
  region: Region;
  lifecycle: Lifecycle;
  lastMicrovmId: string | null;
  lastEndpoint: string | null;
  runs: RunRecord[];
  loading: boolean;
  error: string | null;
}

const state: AppState = {
  variant: "base",
  region: "us-east-1",
  lifecycle: "idle30",
  lastMicrovmId: null,
  lastEndpoint: null,
  runs: [],
  loading: false,
  error: null,
};

// ── CodeMirror editor (singleton; re-attached after each render) ──────────────
let editorView: EditorView | null = null;

function buildExtensions() {
  return [
    lineNumbers(),
    highlightActiveLineGutter(),
    highlightSpecialChars(),
    history(),
    foldGutter(),
    drawSelection(),
    dropCursor(),
    rectangularSelection(),
    crosshairCursor(),
    highlightActiveLine(),
    highlightSelectionMatches(),
    indentOnInput(),
    syntaxHighlighting(defaultHighlightStyle, { fallback: true }),
    bracketMatching(),
    closeBrackets(),
    python(),
    oneDark,
    keymap.of([
      ...defaultKeymap,
      ...historyKeymap,
      ...foldKeymap,
      ...closeBracketsKeymap,
      ...searchKeymap,
    ]),
    EditorView.lineWrapping,
  ];
}

function mountEditor(container: HTMLElement): void {
  if (editorView) {
    // Re-attach existing view to new DOM node
    container.appendChild(editorView.dom);
    return;
  }
  const startState = EditorState.create({
    doc: SAMPLES[state.variant],
    extensions: buildExtensions(),
  });
  editorView = new EditorView({ state: startState, parent: container });
}

function getCode(): string {
  return editorView ? editorView.state.doc.toString() : "";
}

function setCode(code: string): void {
  if (!editorView) return;
  editorView.dispatch({
    changes: { from: 0, to: editorView.state.doc.length, insert: code },
  });
}

// ── Action dispatch ───────────────────────────────────────────────────────────
export async function dispatch(action: Action): Promise<void> {
  if (state.loading) return;

  if (
    (action === "reuse" || action === "suspend" || action === "terminate") &&
    !state.lastMicrovmId
  ) {
    state.error =
      "No microvmId from a previous run. Run (cold create) first.";
    re_render();
    return;
  }

  state.loading = true;
  state.error = null;
  re_render();

  try {
    const needsCode = action === "run" || action === "reuse";
    const code = needsCode ? getCode() : undefined;

    const result = await callProvisioner(state.region, {
      action,
      variant: state.variant,
      lifecycle: state.lifecycle,
      code,
      microvmId: state.lastMicrovmId ?? undefined,
      endpoint: state.lastEndpoint ?? undefined,
      wantImage: true,
      timeoutMs: 15000,
    });

    const resp: BenchResponse = result.response;

    if (resp.microvmId) state.lastMicrovmId = resp.microvmId;
    if (resp.endpoint) state.lastEndpoint = resp.endpoint;

    const record: RunRecord = {
      id: `${Date.now()}-${Math.random().toString(36).slice(2, 7)}`,
      clientMs: result.clientMs,
      request: {
        action,
        variant: state.variant,
        lifecycle: state.lifecycle,
        code,
        microvmId: resp.microvmId ?? state.lastMicrovmId ?? undefined,
        endpoint: resp.endpoint ?? state.lastEndpoint ?? undefined,
        wantImage: true,
        timeoutMs: 15000,
      },
      response: resp,
      region: state.region,
      timestamp: Date.now(),
    };

    state.runs = [record, ...state.runs].slice(0, 50);
  } catch (err: unknown) {
    state.error = err instanceof Error ? err.message : String(err);
  } finally {
    state.loading = false;
    re_render();
  }
}

// ── State setters ─────────────────────────────────────────────────────────────
export function setVariant(v: Variant): void {
  state.variant = v;
  setCode(SAMPLES[v]);
  re_render();
}

export function setRegion(r: Region): void {
  state.region = r;
  re_render();
}

export function setLifecycle(l: Lifecycle): void {
  state.lifecycle = l;
  re_render();
}

// ── Render loop ───────────────────────────────────────────────────────────────
function re_render(): void {
  renderUI(state, {
    onVariant: setVariant,
    onRegion: setRegion,
    onLifecycle: setLifecycle,
    onAction: dispatch,
  });
  // Re-attach CodeMirror into the fresh DOM node
  const mountEl = document.getElementById("code-editor-mount");
  if (mountEl) mountEditor(mountEl);
}

// ── Bootstrap ─────────────────────────────────────────────────────────────────
const root = document.getElementById("app")!;
root.innerHTML = `<div id="shell"></div>`;
re_render();
