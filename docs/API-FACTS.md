# API-FACTS — authoritative AWS Lambda MicroVMs surface (verified 2026-06-23)

> Extracted from the **real** `aws lambda-microvms` CLI (`--generate-cli-skeleton`) and the
> **Go SDK** `github.com/aws/aws-sdk-go-v2/service/lambdamicrovms@v1.0.0` on this machine.
> Build against this — the verified surface — not against half-remembered API shapes.

## Account / environment
- Account `<your-account-id>`, an admin IAM user, CLI profile `microvm-bench`.
- Regions under test: **`us-east-1`** and **`us-west-2`** (both high-quota Regions; 1024 GB mem quota).
- Managed base image (BOTH regions confirmed present):
  - `arn:aws:lambda:us-east-1:aws:microvm-image:al2023-1`
  - `arn:aws:lambda:us-west-2:aws:microvm-image:al2023-1`
- AWS-managed connectors (per region, substitute region in ARN):
  - ingress all: `arn:aws:lambda:<region>:aws:network-connector:aws-network-connector:ALL_INGRESS`
  - egress internet: `arn:aws:lambda:<region>:aws:network-connector:aws-network-connector:INTERNET_EGRESS`
- Go SDK deps that resolve: `aws-sdk-go-v2 v1.42.0`, `service/lambdamicrovms v1.0.0`,
  `smithy-go v1.27.1`. `go get github.com/aws/aws-sdk-go-v2/service/lambdamicrovms@latest` works.

## CLI namespaces
- `aws lambda-microvms ...` — microVM + image ops.
- `aws lambda-core ...` — network connectors (`create/get/delete-network-connector`).

## create-microvm-image — REAL input shape (CLI skeleton)
```json
{
  "name": "",
  "baseImageArn": "",                      // REQUIRED
  "baseImageVersion": "",
  "buildRoleArn": "",                      // REQUIRED (Go: required; CLI lets you omit → no build logs)
  "codeArtifact": { "uri": "s3://..." },   // REQUIRED, union member "uri"
  "cpuConfigurations": [ { "architecture": "ARM_64" } ],   // ARM_64 only
  "resources": [ { "minimumMemoryInMiB": 0 } ],            // <-- BASELINE MEMORY lives here, NOT a "memory" field
  "additionalOsCapabilities": [ "ALL" ],                   // only legal value is ["ALL"]; omit otherwise
  "environmentVariables": { "KeyName": "" },               // image-level, shared across all microVMs
  "egressNetworkConnectors": [ "" ],                       // BUILD-TIME egress (e.g. to pull wheels)
  "hooks": {
    "port": 0,                                             // single port ALL hooks are served on
    "microvmHooks":      { "run": "DISABLED", "runTimeoutInSeconds": 0,
                           "resume": "DISABLED", "resumeTimeoutInSeconds": 0,
                           "suspend": "DISABLED", "suspendTimeoutInSeconds": 0,
                           "terminate": "DISABLED", "terminateTimeoutInSeconds": 0 },
    "microvmImageHooks": { "ready": "DISABLED", "readyTimeoutInSeconds": 0,
                           "validate": "DISABLED", "validateTimeoutInSeconds": 0 }
  },
  "logging": { "cloudWatch": { "logGroup": "", "logStream": "" } },  // or { "disabled": {} }
  "tags": { "KeyName": "" },
  "clientToken": ""
}
```
- Hook flags are the **string enum** `"ENABLED" | "DISABLED"` (Go: `types.HookState`). To use a hook,
  set it `"ENABLED"` and give a timeout (1–3600 s). All enabled hooks share the one `hooks.port`.
- `resources[].minimumMemoryInMiB` sets the **baseline** (2 GB:1 vCPU; peak = 4× baseline). This is the
  single most cost-sensitive knob. Default if omitted ≈ 2048 MiB.

## run-microvm — REAL input shape (CLI skeleton)
```json
{
  "imageIdentifier": "",                   // REQUIRED (image ARN or name)
  "imageVersion": "",
  "ingressNetworkConnectors": [ "" ],
  "egressNetworkConnectors":  [ "" ],
  "executionRoleArn": "",
  "idlePolicy": { "maxIdleDurationSeconds": 0, "suspendedDurationSeconds": 0, "autoResumeEnabled": true },
  "logging": { "cloudWatch": { "logGroup": "", "logStream": "" } },
  "runHookPayload": "",                    // <=16384 bytes, delivered as /run body
  "maximumDurationInSeconds": 0,           // 1..28800 — ALWAYS SET THIS (hard cost ceiling)
  "clientToken": ""
}
```
`RunMicrovmOutput` (Go) returns: `MicrovmId`, `Endpoint`, `State` (starts `PENDING`), `StateReason`,
`ImageArn`, `ImageVersion`, `MaximumDurationInSeconds`, `StartedAt`, `IdlePolicy`, connectors,
`ExecutionRoleArn`, `TerminatedAt`. **No polling**: the endpoint is usable immediately via the
send-and-hold readiness strategy (see README / CONTRACTS §B).

`types.IdlePolicy` — ALL THREE fields are required pointers:
`AutoResumeEnabled *bool`, `MaxIdleDurationSeconds *int32`, `SuspendedDurationSeconds *int32`.
- **VERIFIED LIVE 2026-06-23:** `maxIdleDurationSeconds` must be **>= 60** (RunMicrovm
  rejects 30 with `ValidationException: ... Member must have value greater than or equal
  to 60`). The presets bump ephemeral/idle30 to 60 (CONTRACTS §G).

## create-microvm-auth-token — REAL input shape
```json
{ "microvmIdentifier": "", "expirationInMinutes": 0,
  "allowedPorts": [ { "port": 0, "range": { "startPort": 0, "endPort": 0 }, "allPorts": {} } ] }
```
- **`expirationInMinutes` MAX = 60** (Go SDK doc; reference's "30" was just an example).
- `allowedPorts` is a **union** — supply exactly ONE of `{"port":N}` | `{"range":{...}}` | `{"allPorts":{}}`
  per element. Go: `types.PortSpecificationMemberAllPorts{Value: types.Unit{}}` etc.
- Output: `AuthToken map[string]string`; use `AuthToken["X-aws-proxy-auth"]` as the header value.

## MicrovmState enum (Go `types.MicrovmState`)
`PENDING → RUNNING → SUSPENDING → SUSPENDED → TERMINATING → TERMINATED` (string values as written).

## Go SDK operations available (api_op_*.go)
CreateMicrovmAuthToken, CreateMicrovmImage, CreateMicrovmShellAuthToken, DeleteMicrovmImage,
DeleteMicrovmImageVersion, GetMicrovm, GetMicrovmImage, GetMicrovmImageBuild, GetMicrovmImageVersion,
ListManagedMicrovmImageVersions, ListManagedMicrovmImages, ListMicrovmImageBuilds,
ListMicrovmImageVersions, ListMicrovmImages, ListMicrovms, ListTags, ResumeMicrovm, RunMicrovm,
SuspendMicrovm, TagResource, TerminateMicrovm, UntagResource, UpdateMicrovmImage,
UpdateMicrovmImageVersion.

Go client construction:
```go
import (
  "github.com/aws/aws-sdk-go-v2/config"
  mvm "github.com/aws/aws-sdk-go-v2/service/lambdamicrovms"
  mvmtypes "github.com/aws/aws-sdk-go-v2/service/lambdamicrovms/types"
)
cfg, _ := config.LoadDefaultConfig(ctx, config.WithRegion(region))
c := mvm.NewFromConfig(cfg)
out, err := c.RunMicrovm(ctx, &mvm.RunMicrovmInput{ ImageIdentifier: aws.String(arn), ... })
```

## Fixed quotas / rate limits that constrain design
- API TPS (per account per region, FIXED): RunMicrovm **5**, ResumeMicrovm **5**, SuspendMicrovm **2**,
  TerminateMicrovm **10**, GetMicrovm 100, CreateMicrovmAuthToken **50**. Retry with backoff+jitter.
  → The harness MUST throttle RunMicrovm to ≤5/s; never loop GetMicrovm on a hot path.
- Memory quota 1024 GB across RUNNING+SUSPENDED in us-east-1/us-west-2 (plenty for this bench).
- Concurrent image builds: 10 in these regions.
- `runHookPayload` ≤ 16384 bytes. env vars/image ≤ 50. connectors 0–10 each. hook timeouts 1–3600 s.

## Lifecycle hook HTTP contract (app implements these; Lambda calls them)
Base path on `hooks.port`: `/aws/lambda-microvms/runtime/v1/`
- `ready`    POST → 200 ready / 503 retry-immediately   (BUILD time, under build role)
- `validate` POST → 200 pass / 503 retry  (BUILD time; can prefetch snapshot regions via mock payloads)
- `run`      POST body `{ "microvmId": "...", "runHookPayload": "..." }` → 200. **Traffic starts only after 200.**
- `resume`   POST → 200  (re-establish sockets/threads; microVM stays SUSPENDED until 200)
- `suspend`  POST → 200  (flush/cleanup before checkpoint)
- `terminate`POST → 200  (final flush)
> Return 503 IMMEDIATELY (don't hold the socket) or Lambda kills the build.
> `/run` failure/timeout can skip RUNNING and go straight to TERMINATING.

## Endpoint data-plane (client → microVM)
- URL: `https://<microvmId>.lambda-microvm.<region>.on.aws`
- Every request needs header `X-aws-proxy-auth: <token>`. Default port 8080; override via
  `X-aws-proxy-port` (must be in token allowedPorts) or WS subprotocol `lambda-microvms.port.N`.
- `X-aws-proxy-*` headers are reserved and stripped before reaching the app.
- Endpoint error codes: 403 (bad/expired token or port), 429 (rate), 502 (app not up / resume failed).

## Pricing constants (us-east-1, ARM) — for the cost calculator
- vCPU: `$0.0000276944` /vCPU-s · memory: `$0.0000036667` /GB-s
- snapshot WRITE (suspend): `$0.0038` /GB · snapshot READ (launch+resume): `$0.00155` /GB
- snapshot STORAGE: `$0.08` /GB-month · image storage min retention 1 week.

## Deploy-time verified facts (2026-06-23)
- **Lambda Function URL auth:** this account's Org SCP **blocks public (auth `NONE`)
  Function URLs** — a correct `principal:"*"` / `lambda:FunctionUrlAuthType:NONE`
  resource policy still returns **403**. Use `authorization_type = "AWS_IAM"` and
  **SigV4-sign** requests (service `lambda`, e.g. `curl --aws-sigv4 "aws:amz:<region>:lambda"`).
  The harness signs with its profile creds; a browser SPA needs SigV4 or a signing relay.
- **Function URL CORS:** `allowMethods` rejects `"OPTIONS"` (max length 6; preflight is
  automatic) — use `["POST"]`. `allowOrigins` rejects subdomain wildcards like
  `https://*.example.com` — only exact origins or `"*"`.
- **idlePolicy.maxIdleDurationSeconds >= 60** (see run-microvm above).
- **Image CLI:** `get-microvm-image --image-identifier <name|arn>` (NOT `--image-name`).
  `get-microvm-image-build` requires `--image-identifier --image-version --build-id`.
  create/update responses carry **no `buildId`**; poll readiness via
  `get-microvm-image --image-identifier <arn>` `.state` (`CREATING` → `CREATED` /
  `CREATE_FAILED`). `create-microvm-image` flags confirmed: `--name --base-image-arn
  --build-role-arn --code-artifact --cpu-configurations --resources --hooks
  --egress-network-connectors --tags` (+ optional `--additional-os-capabilities`,
  `--environment-variables`). IAM action prefix for ALL microvm ops is **`lambda:`**
  (Service Authorization Reference); resource type `microvmImage` (wildcard `*` ok).
  Build + exec role trust principal: **`lambda.amazonaws.com`** (`sts:AssumeRole`,
  `sts:TagSession`). `executionRoleArn` on run-microvm is **optional**.
- **matplotlib shake-down:** font_manager loads `LastResortHE-Regular.ttf`
  unconditionally at import — the font allowlist must keep `DejaVu*` AND `LastResort*`.
- **`hooks.port` MUST be 9000, not 8080.** 8080 is the data-plane `/exec` endpoint default; AWS's
  build-time lifecycle-hook channel never delivers its POST to an app whose `hooks.port` is 8080
  (the build fails `Ready hook invocation timed out` even though the app is listening). The manager
  binds **both** 9000 (hooks) and 8080 (data-plane `/exec`). Hooks arrive over HTTP/1.1 cleartext;
  build hooks need neither an ingress nor an egress connector (AWS provides build-time internet).
  `/ready` and `/validate` should answer quickly and never hold the socket.
