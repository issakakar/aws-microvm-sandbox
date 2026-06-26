// CONTRACTS §A — exact field names, enum values frozen

export type Variant = "base" | "mpl" | "sci";
export type Region = "us-east-1" | "us-west-2";
export type Lifecycle = "ephemeral" | "idle30" | "idle60" | "max5" | "max10";
export type Action = "run" | "reuse" | "suspend" | "terminate";
export type Regime = "cold-create" | "warm-resume" | "hot" | "control";

// §A request
export interface BenchRequest {
  action: Action;
  variant: Variant;
  lifecycle: Lifecycle;
  code?: string;
  microvmId?: string;
  endpoint?: string;
  wantImage: boolean;
  timeoutMs: number;
}

// §A response
export interface ProvisionerTimings {
  lambdaCold: boolean;
  runMicrovmMs: number;
  tokenMintMs: number;
  tokenOverlapMs: number;
  execRttMs: number;
  firstAttemptHeld: boolean;
  execRetries: number;
  totalMs: number;
}

export interface InvmTimings {
  sinceRunHookMs: number;
  dispatchMs: number;
  forkMs: number;
  preforkUsed: boolean;
  userCodeMs: number;
  firstImportTouchMs: number;
  renderMs: number;
  serializeMs: number;
  totalMs: number;
  resumedSinceLastExec: boolean;
}

export interface ExecResult {
  ok: boolean;
  stdout: string;
  stderr: string;
  imagePngB64: string | null;
  error: string | null;
}

export interface BenchResponse {
  ok: boolean;
  microvmId: string;
  endpoint: string;
  state: "RUNNING" | "SUSPENDED" | "TERMINATED" | "PENDING";
  regime: Regime;
  result: ExecResult | null;
  timings: {
    provisioner: ProvisionerTimings;
    invm: InvmTimings | null;
  };
  costEstimateUsd: number;
  error: string | null;
}

// UI state
export interface RunRecord {
  id: string; // local sequential id
  clientMs: number; // performance.now() end-to-end
  request: BenchRequest;
  response: BenchResponse;
  region: Region;
  timestamp: number; // Date.now() — only for display order, not measurement
}
