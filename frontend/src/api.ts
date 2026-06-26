// Browser → CloudFront (same origin) → OAC SigV4 → AWS_IAM provisioner Function
// URL. The whole path is AWS: CloudFront Origin Access Control signs each /api/*
// request with SigV4 on the browser's behalf, so the browser never holds AWS
// creds and there is no cross-cloud hop. Region is chosen by PATH — /api/use1/*
// → us-east-1, /api/usw2/* → us-west-2 — which CloudFront routes to the matching
// Lambda-URL origin. performance.now() wraps the fetch — the only client clock.
import type { BenchRequest, BenchResponse, Region } from "./types.js";

export interface CallResult {
  response: BenchResponse;
  clientMs: number; // performance.now() round-trip (browser → CloudFront → provisioner)
}

// Access gate: CloudFront requires a token on /api/* when one is configured. The
// SPA reads it once from the URL (?k=...), persists it, and sends it as X-Gate.
// This keeps a found CloudFront URL from spending AWS — the token is NOT baked
// into the bundle.
function gateToken(): string {
  try {
    const fromUrl = new URLSearchParams(location.search).get("k");
    if (fromUrl) localStorage.setItem("mvb_gate", fromUrl);
    return localStorage.getItem("mvb_gate") ?? "";
  } catch {
    return "";
  }
}

// regionSlug maps the region enum to the CloudFront path prefix that routes to
// that region's Lambda-URL origin.
function regionSlug(region: Region): string {
  return region === "us-west-2" ? "usw2" : "use1";
}

// sha256Hex returns the lowercase hex SHA-256 of a string (UTF-8). CloudFront OAC
// does NOT hash request bodies for POST → the client MUST send the body hash in
// x-amz-content-sha256, which CloudFront then includes in its SigV4 signature to
// the Lambda URL (Lambda rejects unsigned payloads). Web Crypto is available
// because the app is served over HTTPS.
async function sha256Hex(s: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s));
  return Array.from(new Uint8Array(digest))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

export async function callProvisioner(
  region: Region,
  body: BenchRequest
): Promise<CallResult> {
  // The hashed bytes MUST be byte-identical to what we send, so stringify once.
  // Compute the hash BEFORE starting the client clock (it's off the network path).
  const bodyStr = JSON.stringify(body);
  const contentHash = await sha256Hex(bodyStr);
  const t0 = performance.now();
  const res = await fetch(`/api/${regionSlug(region)}/run`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "X-Gate": gateToken(),
      "x-amz-content-sha256": contentHash,
    },
    body: bodyStr,
  });
  const clientMs = performance.now() - t0;

  // The provisioner returns a CONTRACT-shaped JSON body even on failure (HTTP 502
  // with {ok:false,error,...,timings}). Parse regardless of status so failed-but-
  // timed runs keep clientMs + timings and render via the UI error branch. Only a
  // non-JSON body is a true transport error.
  const text = await res.text();
  let parsed: BenchResponse;
  try {
    parsed = JSON.parse(text) as BenchResponse;
  } catch {
    throw new Error(`HTTP ${res.status} from CloudFront (non-JSON body): ${text.slice(0, 500)}`);
  }
  return { response: parsed, clientMs };
}
