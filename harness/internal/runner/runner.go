// Package runner orchestrates the benchmark matrix: (region x variant x regime) x N samples.
package runner

import (
	"context"
	"fmt"
	"time"

	"microvm-bench/harness/internal/client"
	"microvm-bench/harness/internal/results"
)

// Params configures one benchmark run.
type Params struct {
	Regions   []string // e.g. ["us-east-1", "us-west-2"]
	Variants  []string // "base", "mpl", "sci"
	Regimes   []string // "cold-create", "hot", "warm-resume"
	Lifecycle string   // "ephemeral" | "idle30" | "idle60" | "max5" | "max10"
	Samples   int
	DryRun    bool

	// URLForRegion maps region → Function URL.
	URLForRegion func(region string) (string, error)

	// Logger is called for progress lines (nil = silent).
	Logger func(format string, args ...any)
}

// sampleCode is the default payload per variant (§H CONTRACTS.md).
var sampleCode = map[string]string{
	"base": "print(sum(i*i for i in range(10_000)))",
	// mpl/sci build a figure but do NOT savefig themselves — the worker captures
	// the current figure when wantImage=true (renderMs + base64 PNG round-trip),
	// which is the real interactive "return a chart" path the gate must measure. A
	// user-code savefig would double-render and skew renderMs.
	"mpl": `import numpy as np
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
x = np.linspace(0, 2*np.pi, 200)
plt.plot(x, np.sin(x))
plt.title('sine')
print('done')`,
	"sci": `import pandas as pd
import seaborn as sns
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
df = pd.DataFrame({'x': range(10), 'y': range(10)})
sns.barplot(x='x', y='y', data=df)
print('done')`,
}

// lifecycleForRegime returns the lifecycle preset appropriate for the regime.
// If the caller already specified a lifecycle, that takes precedence.
func lifecycleForRegime(regime, override string) string {
	if override != "" {
		return override
	}
	switch regime {
	case "cold-create":
		return "ephemeral" // terminate after exec
	case "hot", "warm-resume":
		return "idle30"
	default:
		return "ephemeral"
	}
}

// log calls p.Logger if set.
func (p *Params) log(format string, args ...any) {
	if p.Logger != nil {
		p.Logger(format, args...)
	}
}

// Run executes the full benchmark matrix and returns collected samples.
// It always attempts to terminate microVMs it created, even on error.
func Run(ctx context.Context, p Params) ([]results.Sample, error) {
	var allSamples []results.Sample

	for _, region := range p.Regions {
		for _, variant := range p.Variants {
			for _, regime := range p.Regimes {
				lc := lifecycleForRegime(regime, p.Lifecycle)
				samples, err := runCell(ctx, p, region, variant, regime, lc)
				if err != nil {
					p.log("[%s/%s/%s] cell error: %v", region, variant, regime, err)
				}
				allSamples = append(allSamples, samples...)
			}
		}
	}
	return allSamples, nil
}

// runCell runs N samples for a single (region, variant, regime) combination.
func runCell(ctx context.Context, p Params, region, variant, regime, lifecycle string) ([]results.Sample, error) {
	url, err := p.URLForRegion(region)
	if err != nil {
		return nil, err
	}

	// Extend HTTP timeout for cold-create (Lambda boot + exec can take several seconds).
	httpTimeout := 45 * time.Second
	c := client.NewWithTimeout(url, region, httpTimeout)

	code := sampleCode[variant]
	if code == "" {
		code = "print('hello')"
	}

	var samples []results.Sample

	// State carried between samples for hot/warm-resume regimes.
	var currentMicrovmID string
	var currentEndpoint string

	// Always terminate microvms we created when done with this cell.
	defer func() {
		if currentMicrovmID != "" && regime != "cold-create" {
			p.log("[%s/%s/%s] terminating %s ...", region, variant, regime, currentMicrovmID)
			if p.DryRun {
				p.log("[dry-run] would terminate %s", currentMicrovmID)
				return
			}
			termCtx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
			defer cancel()
			termReq := client.ProvisionerRequest{
				Action:    "terminate",
				Variant:   variant,
				Lifecycle: lifecycle,
				MicrovmID: currentMicrovmID,
			}
			_, _, termErr := c.Do(termCtx, termReq)
			if termErr != nil {
				p.log("[%s/%s/%s] terminate error: %v", region, variant, regime, termErr)
			}
		}
	}()

	for i := 0; i < p.Samples; i++ {
		s := results.Sample{
			SampleIdx: i,
			Region:    region,
			Variant:   variant,
			Regime:    regime,
			Lifecycle: lifecycle,
		}

		p.log("[%s/%s/%s] sample %d/%d ...", region, variant, regime, i+1, p.Samples)

		if p.DryRun {
			p.log("[dry-run] would POST action=%s variant=%s lifecycle=%s", actionForRegime(regime, i, currentMicrovmID), variant, lifecycle)
			s.OK = true
			s.MicrovmID = "dry-run-mvm-id"
			samples = append(samples, s)
			continue
		}

		req, err := buildRequest(regime, i, variant, lifecycle, code, currentMicrovmID, currentEndpoint)
		if err != nil {
			s.ErrorMsg = err.Error()
			samples = append(samples, s)
			continue
		}

		// Throttle: RunMicrovm is capped at 5/s (API-FACTS.md). Sequential is fine; just wait
		// a 200 ms floor between cold creates to stay well within the limit.
		if req.Action == "run" && i > 0 {
			time.Sleep(200 * time.Millisecond)
		}

		resp, elapsed, doErr := c.Do(ctx, req)
		s.ClientMs = float64(elapsed.Milliseconds())

		if doErr != nil {
			s.ErrorMsg = doErr.Error()
			samples = append(samples, s)
			p.log("[%s/%s/%s] sample %d error: %v", region, variant, regime, i+1, doErr)
			continue
		}

		s.OK = resp.OK
		s.MicrovmID = resp.MicrovmID
		s.CostEstimate = resp.CostEstimateUSD
		if resp.Error != nil {
			s.ErrorMsg = *resp.Error
		}
		if resp.Timings != nil {
			s.Provisioner = resp.Timings.Provisioner
			s.InVM = resp.Timings.InVM
		}

		// Update state for subsequent samples in hot/warm-resume regimes.
		if resp.MicrovmID != "" {
			currentMicrovmID = resp.MicrovmID
			currentEndpoint = resp.Endpoint
		}

		if regime == "warm-resume" && i < p.Samples-1 {
			// Suspend before next sample so we measure SUSPENDED→RUNNING.
			p.log("[%s/%s/%s] suspending %s for next sample ...", region, variant, regime, currentMicrovmID)
			suspReq := client.ProvisionerRequest{
				Action:    "suspend",
				Variant:   variant,
				Lifecycle: lifecycle,
				MicrovmID: currentMicrovmID,
			}
			_, _, suspErr := c.Do(ctx, suspReq)
			if suspErr != nil {
				p.log("[%s/%s/%s] suspend warning: %v", region, variant, regime, suspErr)
			}
		}

		samples = append(samples, s)
		p.log("[%s/%s/%s] sample %d ok clientMs=%.0f totalMs=%.0f",
			region, variant, regime, i+1, s.ClientMs, provTotalMs(resp))
	}

	return samples, nil
}

// buildRequest constructs the ProvisionerRequest for a given regime + sample index.
func buildRequest(regime string, sampleIdx int, variant, lifecycle, code, existingID, existingEndpoint string) (client.ProvisionerRequest, error) {
	base := client.ProvisionerRequest{
		Variant:   variant,
		Lifecycle: lifecycle,
		Code:      code,
		// Request the rendered PNG for the viz variants so the gate measures the
		// real render→PNG→base64→return path, not just code execution.
		WantImage: variant == "mpl" || variant == "sci",
		TimeoutMs: 10000,
	}

	switch regime {
	case "cold-create":
		// Each sample is a fresh cold create with ephemeral lifecycle.
		base.Action = "run"
	case "hot":
		if sampleIdx == 0 || existingID == "" {
			// First sample: cold create.
			base.Action = "run"
		} else {
			// Subsequent samples: reuse the already-running VM.
			base.Action = "reuse"
			base.MicrovmID = existingID
			base.Endpoint = existingEndpoint
		}
	case "warm-resume":
		if sampleIdx == 0 || existingID == "" {
			// First sample: cold create.
			base.Action = "run"
		} else {
			// Subsequent samples: exec against the (just-suspended) VM → triggers auto-resume.
			base.Action = "reuse"
			base.MicrovmID = existingID
			base.Endpoint = existingEndpoint
		}
	default:
		return client.ProvisionerRequest{}, fmt.Errorf("unknown regime %q", regime)
	}
	return base, nil
}

// actionForRegime is used in dry-run logging only.
func actionForRegime(regime string, idx int, existingID string) string {
	switch regime {
	case "cold-create":
		return "run"
	case "hot", "warm-resume":
		if idx == 0 || existingID == "" {
			return "run"
		}
		return "reuse"
	default:
		return "run"
	}
}

// provTotalMs extracts provisioner totalMs from a response safely.
func provTotalMs(resp *client.ProvisionerResponse) float64 {
	if resp == nil || resp.Timings == nil || resp.Timings.Provisioner == nil {
		return 0
	}
	return resp.Timings.Provisioner.TotalMs
}
