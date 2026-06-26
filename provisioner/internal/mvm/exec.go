package mvm

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"time"
)

// execHTTPClient is the data-plane client. Its transport timeout is a generous
// backstop; the REAL per-attempt bound is perAttemptTimeout, enforced via a
// per-attempt sub-context, so a cold endpoint that holds the socket then 502s
// cannot burn the whole budget on a single doomed attempt.
var execHTTPClient = &http.Client{Timeout: 21 * time.Second}

// sendHoldTimeout bounds the overall /exec phase including retries.
const sendHoldTimeout = 30 * time.Second

// perAttemptTimeout caps a SINGLE /exec attempt.
//
// MEASURED RATIONALE (us-east-1, 2026-06-25, n=15 cold-create): a cold
// PENDING→RUNNING holds the inbound request only ~17% of the time. When it does
// NOT hold, AWS's endpoint keeps the connection open ~3.1s then returns 502 —
// pure waste, because the VM is RUNNING (its /run hook already fired) long
// before that. The held-and-succeed cases returned in ~1.4s. So we cap each
// attempt just above that hold-success time: long enough to ride a genuine hold
// to a 200, short enough to abandon a doomed 3s hold and re-probe the
// now-routable endpoint. A per-attempt deadline (distinct from the overall
// phase deadline) is treated as RETRYABLE, not fatal.
const perAttemptTimeout = 1500 * time.Millisecond

// maxHoldWindow caps the wall-clock spent probing before giving up.
const maxHoldWindow = 15 * time.Second

// execOutcome carries the result of the send-and-hold /exec phase.
type execOutcome struct {
	Result           ExecResult
	InVM             *InVMTimings
	ExecRttMs        float64
	FirstAttemptHeld bool
	ExecRetries      int
	HTTPStatus       int
}

// backoffSchedule is the INTER-attempt pause. With perAttemptTimeout now doing
// the waiting, the pause only needs to avoid hammering the endpoint: a short,
// mildly-growing gap (100,150,200,…,500ms capped) so we re-probe within a few
// hundred ms of the endpoint becoming routable — instead of the old
// 50→4000ms doubling, whose later steps injected SECONDS of dead time between
// probes and dominated the unheld-cold latency.
func backoffSchedule() []time.Duration {
	var out []time.Duration
	d := 100 * time.Millisecond
	var total time.Duration
	for total+d <= maxHoldWindow {
		out = append(out, d)
		total += d
		d += 50 * time.Millisecond
		if d > 500*time.Millisecond {
			d = 500 * time.Millisecond
		}
	}
	return out
}

// SendAndHold POSTs the exec request to the microVM data-plane endpoint with the
// auth token and holds the first attempt; on 502 / connection-refused it retries
// with bounded backoff. endpoint is the host (no scheme).
func SendAndHold(ctx context.Context, endpoint, port, token string, req Request) (execOutcome, error) {
	var out execOutcome

	body, err := json.Marshal(execRequest{
		Code:      req.Code,
		WantImage: req.WantImage,
		TimeoutMs: req.TimeoutMs,
	})
	if err != nil {
		return out, fmt.Errorf("marshal exec request: %w", err)
	}

	url := fmt.Sprintf("https://%s/exec", endpoint)

	phaseCtx, cancel := context.WithTimeout(ctx, sendHoldTimeout)
	defer cancel()

	backoffs := backoffSchedule()
	attempt := 0
	start := time.Now()

	for {
		attemptStart := time.Now()

		// One attempt, with the per-attempt context scoped to a closure so its
		// cancel covers every internal return AND the body is read while the
		// context is still alive. The closure decides retry/fatal/success; the
		// outer switch acts on it. fatalErr is set only for the fatal verdict.
		var verdict attemptVerdict
		var fatalErr error
		func() {
			attemptCtx, attemptCancel := context.WithTimeout(phaseCtx, perAttemptTimeout)
			defer attemptCancel()

			resp, doErr := doExec(attemptCtx, url, port, token, body)
			if doErr != nil || resp == nil {
				// If the OVERALL phase deadline / caller cancellation fired,
				// stop — fatal.
				if phaseCtx.Err() != nil {
					fatalErr = fmt.Errorf("exec phase ended: %w", phaseCtx.Err())
					verdict = attemptFatal
					return
				}
				// Else: a per-attempt deadline (endpoint held us without routing)
				// or connection-refused/reset (app not up yet) → re-probe.
				// Anything else non-retryable is a genuine fault.
				if !isRetryable(doErr) {
					fatalErr = fmt.Errorf("exec request: %w", doErr)
					verdict = attemptFatal
					return
				}
				verdict = attemptRetry
				return
			}

			defer resp.Body.Close()
			out.HTTPStatus = resp.StatusCode
			switch {
			case resp.StatusCode == http.StatusOK:
				raw, rerr := io.ReadAll(resp.Body)
				if rerr != nil {
					fatalErr = fmt.Errorf("read exec body: %w", rerr)
					verdict = attemptFatal
					return
				}
				var er execResponse
				if jerr := json.Unmarshal(raw, &er); jerr != nil {
					fatalErr = fmt.Errorf("decode exec body: %w", jerr)
					verdict = attemptFatal
					return
				}
				out.Result = ExecResult{
					OK:          er.OK,
					Stdout:      er.Stdout,
					Stderr:      er.Stderr,
					ImagePngB64: er.ImagePngB64,
					Error:       er.Error,
				}
				out.InVM = er.Timings
				out.ExecRttMs = float64(time.Since(attemptStart).Microseconds()) / 1000.0
				out.FirstAttemptHeld = attempt == 0
				verdict = attemptSuccess
			case resp.StatusCode == http.StatusBadGateway:
				// 502 = endpoint not routable yet / app not up → re-probe.
				_, _ = io.Copy(io.Discard, resp.Body)
				verdict = attemptRetry
			default:
				// Non-retryable non-200 (e.g. 403 bad token, 429 rate).
				_, _ = io.Copy(io.Discard, resp.Body)
				fatalErr = fmt.Errorf("exec returned HTTP %d", resp.StatusCode)
				verdict = attemptFatal
			}
		}()

		switch verdict {
		case attemptSuccess:
			return out, nil
		case attemptFatal:
			return out, fatalErr
		}
		// attemptRetry: re-probe after a short pause, unless the budget is spent.
		if attempt >= len(backoffs) || time.Since(start) >= maxHoldWindow {
			return out, fmt.Errorf("exec gave up after %d retries: last HTTP %d", out.ExecRetries, out.HTTPStatus)
		}

		wait := backoffs[attempt]
		attempt++
		out.ExecRetries++
		select {
		case <-phaseCtx.Done():
			return out, fmt.Errorf("exec phase ended: %w", phaseCtx.Err())
		case <-time.After(wait):
		}
	}
}

// attemptVerdict is the outcome of one /exec probe inside SendAndHold's loop.
type attemptVerdict int

const (
	attemptRetry attemptVerdict = iota
	attemptSuccess
	attemptFatal
)

func doExec(ctx context.Context, url, port, token string, body []byte) (*http.Response, error) {
	httpReq, err := http.NewRequestWithContext(ctx, http.MethodPost, url, bytes.NewReader(body))
	if err != nil {
		return nil, err
	}
	httpReq.Header.Set("Content-Type", "application/json")
	httpReq.Header.Set(authTokenHeaderKey, token)
	if port != "" && port != "8080" {
		httpReq.Header.Set("X-aws-proxy-port", port)
	}
	return execHTTPClient.Do(httpReq)
}

// isRetryable reports whether a per-attempt /exec error warrants re-probing.
// The caller has ALREADY ruled out the overall phase deadline / cancellation
// (phaseCtx.Err() != nil) before calling this, so a DeadlineExceeded here can
// only be the PER-ATTEMPT timeout — i.e. the endpoint held us without routing —
// which is exactly the signal to re-probe. A bare context.Canceled with no
// phase-context error is still treated as non-retryable (defensive).
func isRetryable(err error) bool {
	if errors.Is(err, context.Canceled) {
		return false
	}
	if errors.Is(err, context.DeadlineExceeded) {
		// Per-attempt deadline (phase deadline handled by the caller) → re-probe.
		return true
	}
	var netErr net.Error
	if errors.As(err, &netErr) {
		return true
	}
	// net/http wraps connection errors in *url.Error → *net.OpError.
	var opErr *net.OpError
	return errors.As(err, &opErr)
}
