// Command provisioner is the browser-facing Lambda behind a Function URL
// (BUFFERED). It orchestrates the microVM lifecycle per request and returns
// merged timing breakdowns (CONTRACTS §A). One Lambda is
// deployed per region; region comes from the REGION env var.
package main

import (
	"context"
	"encoding/json"
	"log"
	"net/http"
	"sync"
	"sync/atomic"
	"time"

	"github.com/aws/aws-lambda-go/events"
	"github.com/aws/aws-lambda-go/lambda"

	"microvm-bench/provisioner/internal/emf"
	"microvm-bench/provisioner/internal/mvm"
	"microvm-bench/provisioner/internal/pricing"
	"microvm-bench/provisioner/internal/store"
)

// coldStartPending is set at process boot; the FIRST invocation in a fresh
// execution environment swaps it to 0 and reports lambdaCold=true, so the harness
// can subtract Lambda's own cold start.
var coldStartPending atomic.Bool

func init() { coldStartPending.Store(true) }

// Cached AWS clients. The region is fixed per Lambda (REGION env), so a single
// lambdamicrovms client and a single DynamoDB store are built ONCE and reused
// across warm invocations — building them per request re-ran the credential
// chain on the hot path and inflated the measured totalMs.
var (
	apiOnce    sync.Once
	apiClient  mvm.API
	apiInitErr error

	storeOnce sync.Once
	storeInst *store.Store
	storeErr  error
)

func getAPI(ctx context.Context, region string) (mvm.API, error) {
	apiOnce.Do(func() { apiClient, apiInitErr = mvm.NewAPI(ctx, region) })
	return apiClient, apiInitErr
}

func getStore(ctx context.Context, table string) (*store.Store, error) {
	storeOnce.Do(func() { storeInst, storeErr = store.New(ctx, table) })
	return storeInst, storeErr
}

// handler is the Function URL entrypoint (BUFFERED response mode).
func handler(ctx context.Context, evt events.LambdaFunctionURLRequest) (events.LambdaFunctionURLResponse, error) {
	overallStart := time.Now()

	// First real invocation sees true; all later ones false (warm).
	lambdaCold := coldStartPending.CompareAndSwap(true, false)

	// CORS preflight is normally handled by the Function URL config, but answer
	// OPTIONS defensively too.
	if evt.RequestContext.HTTP.Method == http.MethodOptions {
		return jsonResponse(http.StatusNoContent, nil), nil
	}

	cfg, err := mvm.LoadConfig()
	if err != nil {
		return errResponse(http.StatusInternalServerError, "", "", "config: "+err.Error()), nil
	}

	var req mvm.Request
	if err := json.Unmarshal([]byte(evt.Body), &req); err != nil {
		return errResponse(http.StatusBadRequest, "", "", "bad request body: "+err.Error()), nil
	}
	if req.TimeoutMs <= 0 {
		req.TimeoutMs = 10000
	}

	api, err := getAPI(ctx, cfg.Region)
	if err != nil {
		return errResponse(http.StatusInternalServerError, "", "", "aws client: "+err.Error()), nil
	}
	orch := &mvm.Orchestrator{Cfg: cfg, API: api}

	var (
		oc     mvm.Outcome
		runErr error
	)
	switch req.Action {
	case mvm.ActionRun:
		oc, runErr = orch.Run(ctx, req, overallStart, lambdaCold)
	case mvm.ActionReuse:
		oc, runErr = orch.Reuse(ctx, req, overallStart, lambdaCold)
	case mvm.ActionSuspend:
		oc, runErr = orch.Suspend(ctx, req, overallStart, lambdaCold)
	case mvm.ActionTerminate:
		oc, runErr = orch.Terminate(ctx, req, overallStart, lambdaCold)
	default:
		return errResponse(http.StatusBadRequest, "", "", "unknown action: "+string(req.Action)), nil
	}

	// Cost estimate (best-effort math).
	oc.CostEstimateUsd = estimateCost(req, oc)

	// Best-effort observability: EMF + DynamoDB. Never fail the request on these.
	emitObservability(ctx, cfg, req, oc, runErr)

	resp := mvm.Response{
		OK:              runErr == nil,
		MicrovmID:       oc.MicrovmID,
		Endpoint:        oc.Endpoint,
		State:           oc.State,
		Regime:          oc.Regime,
		Result:          oc.Result,
		Timings:         oc.Timings,
		CostEstimateUsd: oc.CostEstimateUsd,
	}
	if runErr != nil {
		msg := runErr.Error()
		resp.Error = &msg
	}

	status := http.StatusOK
	if runErr != nil {
		status = http.StatusBadGateway
	}
	return jsonResponse(status, resp), nil
}

// estimateCost derives the per-run USD estimate (internal/pricing).
func estimateCost(req mvm.Request, oc mvm.Outcome) float64 {
	preset, perr := mvm.PresetFor(req.Lifecycle)
	suspended := false
	if perr == nil {
		// Non-ephemeral presets with autoResume will incur a suspend WRITE.
		suspended = preset.AutoResumeEnabled && preset.SuspendedDurationSeconds > 0
	}
	return pricing.Compute(pricing.Estimate{
		Variant:    req.Variant,
		ComputeMs:  oc.Timings.Provisioner.TotalMs,
		Suspended:  suspended,
		Resumed:    oc.Regime == mvm.RegimeWarmResume,
		ColdCreate: oc.Regime == mvm.RegimeColdCreate,
	})
}

// emitObservability writes one EMF blob and one DynamoDB row, both best-effort.
func emitObservability(ctx context.Context, cfg mvm.Config, req mvm.Request, oc mvm.Outcome, runErr error) {
	pt := oc.Timings.Provisioner
	flat := flattenTimings(oc.Timings)

	dims := map[string]string{
		"region":    cfg.Region,
		"variant":   req.Variant,
		"regime":    oc.Regime,
		"lifecycle": req.Lifecycle,
	}
	// Metric names are snake_case to match the CloudWatch dashboard
	// widgets (infra/modules/region) byte-for-byte — otherwise the dashboards
	// render empty.
	metrics := []emf.Metric{
		{Name: "run_microvm_ms", Value: pt.RunMicrovmMs, Unit: "Milliseconds"},
		{Name: "token_mint_ms", Value: pt.TokenMintMs, Unit: "Milliseconds"},
		{Name: "token_overlap_ms", Value: pt.TokenOverlapMs, Unit: "Milliseconds"},
		{Name: "exec_rtt_ms", Value: pt.ExecRttMs, Unit: "Milliseconds"},
		{Name: "total_ms", Value: pt.TotalMs, Unit: "Milliseconds"},
		{Name: "first_attempt_held", Value: emf.Bool01(pt.FirstAttemptHeld), Unit: "None"},
		{Name: "exec_retries", Value: float64(pt.ExecRetries), Unit: "Count"},
		{Name: "cost_usd", Value: oc.CostEstimateUsd, Unit: "None"},
		{Name: "errors", Value: emf.Bool01(runErr != nil), Unit: "Count"},
	}
	if oc.Timings.InVM != nil {
		iv := oc.Timings.InVM
		metrics = append(metrics,
			emf.Metric{Name: "invm_total_ms", Value: iv.TotalMs, Unit: "Milliseconds"},
			emf.Metric{Name: "fork_ms", Value: iv.ForkMs, Unit: "Milliseconds"},
			emf.Metric{Name: "user_code_ms", Value: iv.UserCodeMs, Unit: "Milliseconds"},
			emf.Metric{Name: "render_ms", Value: iv.RenderMs, Unit: "Milliseconds"},
		)
	}
	// Publish each metric against region-only, region+variant, and the full
	// breakdown so dashboards can aggregate by region (p95 total_ms) as well as
	// drill down. emf drops any set whose keys are empty (e.g. error paths).
	if err := emf.Emit(emf.Blob{
		Dimensions:    dims,
		DimensionSets: [][]string{{"region"}, {"region", "variant"}, {"region", "variant", "regime", "lifecycle"}},
		Metrics:       metrics,
	}); err != nil {
		log.Printf("emf emit failed (ignored): %v", err)
	}

	// DynamoDB best-effort. Skip for missing table or when there's no microVM id.
	if cfg.ResultsTable == "" || oc.MicrovmID == "" {
		return
	}
	st, err := getStore(ctx, cfg.ResultsTable)
	if err != nil {
		log.Printf("store init failed (ignored): %v", err)
		return
	}
	// Use the orchestration runId as the results PK; control actions have none,
	// so mint one.
	runID := oc.RunID
	if runID == "" {
		runID = mvm.NewRunID()
	}
	item := store.Item{
		RunID:            runID,
		Region:           cfg.Region,
		Variant:          req.Variant,
		Regime:           oc.Regime,
		Lifecycle:        req.Lifecycle,
		MicrovmID:        oc.MicrovmID,
		FirstAttemptHeld: pt.FirstAttemptHeld,
		ExecRetries:      pt.ExecRetries,
		Timings:          flat,
		CostEstimateUsd:  oc.CostEstimateUsd,
	}
	if err := st.Put(ctx, item); err != nil {
		log.Printf("store put failed (ignored): %v", err)
	}
}

// flattenTimings flattens provisioner + invm timings into a single map for the
// DynamoDB row (CONTRACTS §F "flattened timings map").
func flattenTimings(t mvm.Timings) map[string]float64 {
	p := t.Provisioner
	m := map[string]float64{
		"runMicrovmMs":   p.RunMicrovmMs,
		"tokenMintMs":    p.TokenMintMs,
		"tokenOverlapMs": p.TokenOverlapMs,
		"execRttMs":      p.ExecRttMs,
		"totalMs":        p.TotalMs,
	}
	if t.InVM != nil {
		iv := t.InVM
		m["invmSinceRunHookMs"] = iv.SinceRunHookMs
		m["invmDispatchMs"] = iv.DispatchMs
		m["invmForkMs"] = iv.ForkMs
		m["invmUserCodeMs"] = iv.UserCodeMs
		m["invmFirstImportTouchMs"] = iv.FirstImportTouchMs
		m["invmRenderMs"] = iv.RenderMs
		m["invmSerializeMs"] = iv.SerializeMs
		m["invmTotalMs"] = iv.TotalMs
	}
	return m
}

// corsHeaders sets Content-Type only. CORS (Allow-Origin/Methods/Headers) is
// owned by the Lambda Function URL's own CORS config (infra/modules/region) —
// emitting CORS headers here too produces DUPLICATE Access-Control-Allow-Origin
// headers, which browsers reject. The Function URL also answers OPTIONS preflight
// before the function runs, so the defensive OPTIONS branch below is a no-op in
// practice and harmless.
func corsHeaders() map[string]string {
	return map[string]string{
		"Content-Type": "application/json",
	}
}

func jsonResponse(status int, body any) events.LambdaFunctionURLResponse {
	resp := events.LambdaFunctionURLResponse{
		StatusCode: status,
		Headers:    corsHeaders(),
	}
	if body == nil {
		return resp
	}
	data, err := json.Marshal(body)
	if err != nil {
		resp.StatusCode = http.StatusInternalServerError
		resp.Body = `{"ok":false,"error":"response marshal failed"}`
		return resp
	}
	resp.Body = string(data)
	return resp
}

// errResponse builds a contract-shaped error Response.
func errResponse(status int, microvmID, endpoint, msg string) events.LambdaFunctionURLResponse {
	return jsonResponse(status, mvm.Response{
		OK:        false,
		MicrovmID: microvmID,
		Endpoint:  endpoint,
		Error:     &msg,
	})
}

func main() {
	lambda.Start(handler)
}
