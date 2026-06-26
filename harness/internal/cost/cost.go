// Package cost implements offline cost estimation using API-FACTS pricing constants.
package cost

import "fmt"

// Pricing constants from API-FACTS.md (us-east-1, ARM64).
const (
	VCPUPerSec    = 0.0000276944 // $/vCPU-s
	MemPerGBSec   = 0.0000036667 // $/GB-s
	SnapWritePerGB = 0.0038      // $/GB (suspend snapshot WRITE)
	SnapReadPerGB  = 0.00155     // $/GB (launch+resume snapshot READ)
	SnapStorePerGBMo = 0.08      // $/GB-month

	// vCPUs at the 2:1 mem:vCPU ratio (baseline). 1 GiB → 0.5 vCPU, 2 GiB → 1 vCPU, etc.
	MemToVCPU = 0.5 // vCPUs per GiB baseline memory
)

// VariantMemGiB maps variant key → baseline memory in GiB.
var VariantMemGiB = map[string]float64{
	"base": 0.5,  // 512 MiB
	"mpl":  1.0,  // 1024 MiB
	"sci":  1.0,  // 1024 MiB
}

// Params holds parameters for the offline estimate subcommand.
type Params struct {
	Regions       []string
	Variants      []string
	Regimes       []string // cold-create, warm-resume, hot
	SamplesPerCell int
	RunDurationSec float64 // average per-run wall-clock execution seconds
	BaselineGB     float64 // override baseline memory; 0 = use per-variant default
}

// Result holds the estimated cost breakdown.
type Result struct {
	ComputeUSD    float64
	SnapReadUSD   float64
	SnapWriteUSD  float64 // warm-resume runs trigger a suspend → snapshot write
	TotalUSD      float64
	TotalRunCount int
	Breakdown     []LineItem
}

// LineItem is a per-cell cost row.
type LineItem struct {
	Region  string
	Variant string
	Regime  string
	Runs    int
	USD     float64
}

// Estimate computes offline cost math (no AWS calls).
// Pricing: ARM64 us-east-1; assumed same for us-west-2 (same tier).
func Estimate(p Params) Result {
	var r Result
	for _, region := range p.Regions {
		for _, variant := range p.Variants {
			memGB := p.BaselineGB
			if memGB <= 0 {
				memGB = VariantMemGiB[variant]
				if memGB == 0 {
					memGB = 1.0 // safe default
				}
			}
			vcpu := memGB * MemToVCPU
			for _, regime := range p.Regimes {
				n := p.SamplesPerCell
				dur := p.RunDurationSec

				computeUSD := float64(n) * dur * (vcpu*VCPUPerSec + memGB*MemPerGBSec)

				// snapshot reads: cold-create and warm-resume each read the snapshot
				var snapReadUSD float64
				if regime == "cold-create" || regime == "warm-resume" {
					snapReadUSD = float64(n) * memGB * SnapReadPerGB
				}
				// snapshot writes: warm-resume = we must have suspended first (one write per resume sample)
				var snapWriteUSD float64
				if regime == "warm-resume" {
					snapWriteUSD = float64(n) * memGB * SnapWritePerGB
				}

				cellUSD := computeUSD + snapReadUSD + snapWriteUSD
				r.ComputeUSD += computeUSD
				r.SnapReadUSD += snapReadUSD
				r.SnapWriteUSD += snapWriteUSD
				r.TotalUSD += cellUSD
				r.TotalRunCount += n
				r.Breakdown = append(r.Breakdown, LineItem{
					Region:  region,
					Variant: variant,
					Regime:  regime,
					Runs:    n,
					USD:     cellUSD,
				})
				_ = region // used above
			}
		}
	}
	return r
}

// FormatTable renders a human-readable table from a Result.
func FormatTable(r Result) string {
	out := fmt.Sprintf("%-12s %-8s %-14s %6s %12s\n", "REGION", "VARIANT", "REGIME", "RUNS", "USD")
	out += "-----------------------------------------------------------\n"
	for _, li := range r.Breakdown {
		out += fmt.Sprintf("%-12s %-8s %-14s %6d %12.6f\n",
			li.Region, li.Variant, li.Regime, li.Runs, li.USD)
	}
	out += "-----------------------------------------------------------\n"
	out += fmt.Sprintf("%-12s %-8s %-14s %6d %12.6f\n",
		"TOTAL", "", "", r.TotalRunCount, r.TotalUSD)
	out += fmt.Sprintf("\n  Compute: $%.6f  SnapRead: $%.6f  SnapWrite: $%.6f\n",
		r.ComputeUSD, r.SnapReadUSD, r.SnapWriteUSD)
	return out
}
