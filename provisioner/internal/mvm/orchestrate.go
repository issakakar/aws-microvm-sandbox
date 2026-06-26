package mvm

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	lmvm "github.com/aws/aws-sdk-go-v2/service/lambdamicrovms"
	"github.com/oklog/ulid/v2"
)

// Orchestrator executes one provisioner request end to end.
type Orchestrator struct {
	Cfg Config
	API API
}

// runHookPayload is the JSON delivered to the worker's /run hook (CONTRACTS §C).
// The worker uses it solely to stamp t_run_done (so /exec can report
// sinceRunHookMs); the user code travels on the inbound /exec channel.
type runHookPayload struct {
	SessionID    string `json:"sessionId"`
	StampRunDone bool   `json:"stampRunDone"`
}

// Outcome is the orchestration result the handler turns into a Response.
type Outcome struct {
	RunID           string
	MicrovmID       string
	Endpoint        string
	State           string
	Regime          string
	Result          *ExecResult
	Timings         Timings
	CostEstimateUsd float64
}

// NewRunID returns a fresh ULID string for the DynamoDB PK (CONTRACTS §F).
func NewRunID() string {
	return ulid.Make().String()
}

// Run handles action=run: cold create, then the classic send-and-hold POST /exec
// on the inbound data-plane endpoint. The token mint runs concurrently with the
// VM's autonomous PENDING→RUNNING boot (it works while PENDING) and gates the
// /exec POST. overallStart is the handler's monotonic origin for totalMs.
func (o *Orchestrator) Run(ctx context.Context, req Request, overallStart time.Time, lambdaCold bool) (Outcome, error) {
	var oc Outcome
	pt := ProvisionerTimings{LambdaCold: lambdaCold}

	imageArn, err := o.Cfg.ImageArn(req.Variant)
	if err != nil {
		return oc, err
	}
	preset, err := PresetFor(req.Lifecycle)
	if err != nil {
		return oc, err
	}

	runID := NewRunID()
	oc.RunID = runID
	clientToken := ulid.Make().String()

	// 1. RunMicrovm — measured.
	runStart := time.Now()
	runOut, err := o.API.RunMicrovm(ctx, runInput(o.Cfg, imageArn, preset, buildRunHookPayload(runID), clientToken))
	pt.RunMicrovmMs = msSince(runStart)
	if err != nil {
		return oc, fmt.Errorf("RunMicrovm: %w", err)
	}
	microvmID := aws.ToString(runOut.MicrovmId)
	endpoint := aws.ToString(runOut.Endpoint)
	if endpoint == "" {
		endpoint = DeriveEndpoint(microvmID, o.Cfg.Region)
	}
	oc.MicrovmID = microvmID
	oc.Endpoint = endpoint
	oc.State = string(runOut.State)

	// Observability: log the runtime microVM descriptor AWS returns (the run-time
	// facts the image API omits). Best-effort, off the latency path.
	logMicrovmDescriptor(runOut)

	// 2. Mint the auth token CONCURRENTLY (works while PENDING, overlaps the VM's
	// autonomous boot); the /exec POST below cannot fire until it is ready.
	tok := <-o.mintTokenAsync(ctx, microvmID, runStart)
	pt.TokenMintMs = tok.mintMs
	pt.TokenOverlapMs = tok.overlapMs
	if tok.err != nil {
		o.failCleanup(ctx, preset, microvmID, &oc, &pt, overallStart)
		return oc, fmt.Errorf("CreateMicrovmAuthToken: %w", tok.err)
	}

	// 3. Send-and-hold POST /exec on the inbound data-plane endpoint.
	exec, eerr := SendAndHold(ctx, endpoint, o.Cfg.ExecPort, tok.token, req)
	pt.ExecRttMs = exec.ExecRttMs
	pt.FirstAttemptHeld = exec.FirstAttemptHeld
	pt.ExecRetries = exec.ExecRetries
	if eerr != nil {
		o.failCleanup(ctx, preset, microvmID, &oc, &pt, overallStart)
		return oc, fmt.Errorf("exec: %w", eerr)
	}

	oc.Result = &exec.Result
	oc.Timings = Timings{Provisioner: pt, InVM: exec.InVM}
	oc.Regime = RegimeColdCreate
	oc.State = string(lmvmStateRunning)

	// 4. Ephemeral → terminate after exec (CONTRACTS §G).
	if preset.TerminateAfterExec {
		o.terminateBestEffort(ctx, microvmID)
		oc.State = string(lmvmStateTerminated)
	}

	pt.TotalMs = msSince(overallStart)
	oc.Timings.Provisioner = pt
	return oc, nil
}

// failCleanup terminates an ephemeral VM on a Run error path and finalizes the
// provisioner timings into oc so the handler still returns a structured response.
func (o *Orchestrator) failCleanup(ctx context.Context, preset Preset, microvmID string, oc *Outcome, pt *ProvisionerTimings, overallStart time.Time) {
	if preset.TerminateAfterExec {
		o.terminateBestEffort(ctx, microvmID)
		oc.State = string(lmvmStateTerminated)
	}
	pt.TotalMs = msSince(overallStart)
	oc.Timings = Timings{Provisioner: *pt}
}

// logMicrovmDescriptor logs the runtime microVM descriptor AWS returns from
// RunMicrovm (microVM id/endpoint/state plus any cpu/memory/snapshot facts it
// carries) as one JSON line, so the run-time truth the image API omits is visible
// in the provisioner's CloudWatch log (grep "microvm_descriptor"). Best-effort.
func logMicrovmDescriptor(out *lmvm.RunMicrovmOutput) {
	if out == nil {
		return
	}
	if b, err := json.Marshal(out); err == nil {
		log.Printf("microvm_descriptor %s", string(b))
	}
}

// buildRunHookPayload builds the stamp-only /run payload (CONTRACTS §C). The
// worker uses it solely to stamp t_run_done (so the first /exec can report
// sinceRunHookMs); the user code travels on the inbound /exec channel.
func buildRunHookPayload(runID string) string {
	b, _ := json.Marshal(runHookPayload{SessionID: runID, StampRunDone: true})
	return string(b)
}

// Reuse handles action=reuse: no RunMicrovm; derive endpoint, mint token, send
// /exec (auto-resume holds if suspended). Regime is read from the worker's
// resumedSinceLastExec — NO GetMicrovm (CONTRACTS §A).
func (o *Orchestrator) Reuse(ctx context.Context, req Request, overallStart time.Time, lambdaCold bool) (Outcome, error) {
	var oc Outcome
	pt := ProvisionerTimings{LambdaCold: lambdaCold}

	if req.MicrovmID == "" {
		return oc, fmt.Errorf("reuse requires microvmId")
	}
	endpoint := req.Endpoint
	if endpoint == "" {
		endpoint = DeriveEndpoint(req.MicrovmID, o.Cfg.Region)
	}
	oc.MicrovmID = req.MicrovmID
	oc.Endpoint = endpoint

	tokenCh := o.mintTokenAsync(ctx, req.MicrovmID, time.Now())
	tok := <-tokenCh
	pt.TokenMintMs = tok.mintMs
	pt.TokenOverlapMs = tok.overlapMs
	if tok.err != nil {
		return oc, fmt.Errorf("CreateMicrovmAuthToken: %w", tok.err)
	}

	exec, err := SendAndHold(ctx, endpoint, o.Cfg.ExecPort, tok.token, req)
	pt.ExecRttMs = exec.ExecRttMs
	pt.FirstAttemptHeld = exec.FirstAttemptHeld
	pt.ExecRetries = exec.ExecRetries
	if err != nil {
		pt.TotalMs = msSince(overallStart)
		oc.Timings = Timings{Provisioner: pt}
		return oc, fmt.Errorf("exec: %w", err)
	}

	oc.Result = &exec.Result
	oc.Timings = Timings{Provisioner: pt, InVM: exec.InVM}
	oc.State = string(lmvmStateRunning)

	// Label regime from the worker, not from a control-plane poll.
	if exec.InVM != nil && exec.InVM.ResumedSinceLastExec {
		oc.Regime = RegimeWarmResume
	} else {
		oc.Regime = RegimeHot
	}

	pt.TotalMs = msSince(overallStart)
	oc.Timings.Provisioner = pt
	return oc, nil
}

// Suspend handles action=suspend (control). result=null.
func (o *Orchestrator) Suspend(ctx context.Context, req Request, overallStart time.Time, lambdaCold bool) (Outcome, error) {
	var oc Outcome
	if req.MicrovmID == "" {
		return oc, fmt.Errorf("suspend requires microvmId")
	}
	_, err := o.API.SuspendMicrovm(ctx, &lmvm.SuspendMicrovmInput{MicrovmIdentifier: aws.String(req.MicrovmID)})
	oc.MicrovmID = req.MicrovmID
	oc.Endpoint = DeriveEndpoint(req.MicrovmID, o.Cfg.Region)
	oc.Regime = RegimeControl
	oc.State = string(lmvmStateSuspended)
	oc.Timings = Timings{Provisioner: ProvisionerTimings{LambdaCold: lambdaCold, TotalMs: msSince(overallStart)}}
	if err != nil {
		return oc, fmt.Errorf("SuspendMicrovm: %w", err)
	}
	return oc, nil
}

// Terminate handles action=terminate (control). result=null.
func (o *Orchestrator) Terminate(ctx context.Context, req Request, overallStart time.Time, lambdaCold bool) (Outcome, error) {
	var oc Outcome
	if req.MicrovmID == "" {
		return oc, fmt.Errorf("terminate requires microvmId")
	}
	_, err := o.API.TerminateMicrovm(ctx, &lmvm.TerminateMicrovmInput{MicrovmIdentifier: aws.String(req.MicrovmID)})
	oc.MicrovmID = req.MicrovmID
	oc.Endpoint = DeriveEndpoint(req.MicrovmID, o.Cfg.Region)
	oc.Regime = RegimeControl
	oc.State = string(lmvmStateTerminated)
	oc.Timings = Timings{Provisioner: ProvisionerTimings{LambdaCold: lambdaCold, TotalMs: msSince(overallStart)}}
	if err != nil {
		return oc, fmt.Errorf("TerminateMicrovm: %w", err)
	}
	return oc, nil
}

// tokenResult bundles the concurrent token-mint outcome.
type tokenResult struct {
	token     string
	mintMs    float64
	overlapMs float64
	err       error
}

// mintTokenAsync mints the auth token in a goroutine started right after
// RunMicrovm returns. The token is REQUIRED before the first /exec POST (a
// missing token yields 403, which exec.go treats as non-retryable), so under
// send-and-hold the mint is necessarily serial in the provisioner — it cannot be
// hidden behind the held request itself. `tokenOverlapMs` therefore reports the
// wall time from overlapStart (RunMicrovm return) until the token was ready:
//   - COLD-CREATE: this overlaps the microVM's *autonomous* boot (the VM boots
//     PENDING→RUNNING whether or not we have POSTed), so it is effectively free
//     when mint < boot — the end-to-end/regime totals reveal the true hiding.
//   - HOT / WARM-RESUME: there is no boot to hide behind, so the same value is
//     pure serial overhead in the time-to-execute budget.
//
// It is NOT a claim that auth is always hidden; read it with tokenMintMs + regime.
// (The "auth is off the critical path" hypothesis is thus testable: it holds for
// cold-create and is refuted for hot — exactly what the harness shows.)
func (o *Orchestrator) mintTokenAsync(ctx context.Context, microvmID string, overlapStart time.Time) <-chan tokenResult {
	ch := make(chan tokenResult, 1)
	go func() {
		mintStart := time.Now()
		out, err := o.API.CreateMicrovmAuthToken(ctx, &lmvm.CreateMicrovmAuthTokenInput{
			MicrovmIdentifier:   aws.String(microvmID),
			ExpirationInMinutes: aws.Int32(authTokenExpirationMinutes),
			AllowedPorts:        allPortsSpec(),
		})
		res := tokenResult{
			mintMs:    msSince(mintStart),
			overlapMs: msSince(overlapStart),
			err:       err,
		}
		if err == nil {
			res.token = out.AuthToken[authTokenHeaderKey]
			if res.token == "" {
				res.err = fmt.Errorf("auth token map missing key %q", authTokenHeaderKey)
			}
		}
		ch <- res
	}()
	return ch
}

// terminateBestEffort terminates a microVM, ignoring errors (cost-control path).
func (o *Orchestrator) terminateBestEffort(ctx context.Context, microvmID string) {
	_, _ = o.API.TerminateMicrovm(ctx, &lmvm.TerminateMicrovmInput{MicrovmIdentifier: aws.String(microvmID)})
}

// msSince returns elapsed milliseconds (float) since t using a monotonic clock.
func msSince(t time.Time) float64 {
	return float64(time.Since(t).Microseconds()) / 1000.0
}

// State string constants mirroring types.MicrovmState values (CONTRACTS §A).
const (
	lmvmStateRunning    = "RUNNING"
	lmvmStateSuspended  = "SUSPENDED"
	lmvmStateTerminated = "TERMINATED"
)
