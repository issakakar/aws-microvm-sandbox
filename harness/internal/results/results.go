// Package results defines the on-disk result format written by the run subcommand.
package results

import (
	"encoding/csv"
	"encoding/json"
	"fmt"
	"math"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"time"

	"microvm-bench/harness/internal/client"
)

// Sample is one individual run measurement.
type Sample struct {
	SampleIdx    int     `json:"sampleIdx"`
	Region       string  `json:"region"`
	Variant      string  `json:"variant"`
	Regime       string  `json:"regime"`
	Lifecycle    string  `json:"lifecycle"`
	MicrovmID    string  `json:"microvmId"`
	ClientMs     float64 `json:"clientMs"`    // wall-clock RTT from harness perspective
	OK           bool    `json:"ok"`
	ErrorMsg     string  `json:"error,omitempty"`
	CostEstimate float64 `json:"costEstimateUsd"`

	Provisioner *client.ProvisionerTimings `json:"provisioner,omitempty"`
	InVM        *client.InVMTimings        `json:"invm,omitempty"`
}

// Stats holds computed p50/p95/min/max for one segment across samples.
type Stats struct {
	P50    float64 `json:"p50"`
	P95    float64 `json:"p95"`
	Min    float64 `json:"min"`
	Max    float64 `json:"max"`
	Mean   float64 `json:"mean"`
	Count  int     `json:"count"`
}

// CellStats aggregates statistics per (region, variant, regime) cell.
type CellStats struct {
	Region  string `json:"region"`
	Variant string `json:"variant"`
	Regime  string `json:"regime"`

	ClientMs      Stats `json:"clientMs"`
	RunMicrovmMs  Stats `json:"runMicrovmMs"`
	TokenMintMs   Stats `json:"tokenMintMs"`
	TokenOverlapMs Stats `json:"tokenOverlapMs"`
	ExecRttMs     Stats `json:"execRttMs"`
	TotalMs       Stats `json:"totalMs"`

	// In-VM breakdown (nil values skipped in aggregation)
	SinceRunHookMs     Stats `json:"sinceRunHookMs"`
	DispatchMs         Stats `json:"dispatchMs"`
	ForkMs             Stats `json:"forkMs"`
	UserCodeMs         Stats `json:"userCodeMs"`
	FirstImportTouchMs Stats `json:"firstImportTouchMs"`
	RenderMs           Stats `json:"renderMs"`
	SerializeMs        Stats `json:"serializeMs"`
	InVMTotalMs        Stats `json:"invmTotalMs"`

	FirstAttemptHeldRate float64 `json:"firstAttemptHeldRate"` // fraction [0,1]
	PreforkUsedRate      float64 `json:"preforkUsedRate"`
	SuccessCount         int     `json:"successCount"`
	TotalCount           int     `json:"totalCount"`
	TotalCostUSD         float64 `json:"totalCostUsd"`
}

// RunResult is the top-level JSON file written per benchmark run.
type RunResult struct {
	Timestamp  time.Time    `json:"timestamp"`
	Samples    []Sample     `json:"samples"`
	CellStats  []CellStats  `json:"cellStats"`
	TotalCostUSD float64    `json:"totalCostUsd"`
}

// Percentile computes the given percentile (0–100) on a sorted float slice.
// The slice must be sorted ascending before calling.
func Percentile(sorted []float64, pct float64) float64 {
	if len(sorted) == 0 {
		return 0
	}
	if len(sorted) == 1 {
		return sorted[0]
	}
	rank := (pct / 100.0) * float64(len(sorted)-1)
	lo := int(math.Floor(rank))
	hi := lo + 1
	if hi >= len(sorted) {
		return sorted[len(sorted)-1]
	}
	frac := rank - float64(lo)
	return sorted[lo]*(1-frac) + sorted[hi]*frac
}

// computeStats derives Stats from a float64 slice (unsorted OK).
func computeStats(vals []float64) Stats {
	if len(vals) == 0 {
		return Stats{}
	}
	cp := make([]float64, len(vals))
	copy(cp, vals)
	sort.Float64s(cp)
	sum := 0.0
	for _, v := range cp {
		sum += v
	}
	return Stats{
		P50:   Percentile(cp, 50),
		P95:   Percentile(cp, 95),
		Min:   cp[0],
		Max:   cp[len(cp)-1],
		Mean:  sum / float64(len(cp)),
		Count: len(cp),
	}
}

// Aggregate computes CellStats across successful samples, grouped by (region, variant, regime).
func Aggregate(samples []Sample) []CellStats {
	type key struct{ region, variant, regime string }
	type collector struct {
		clientMs, runMicrovmMs, tokenMintMs, tokenOverlapMs, execRttMs, totalMs []float64
		sinceRunHookMs, dispatchMs, forkMs, userCodeMs, firstImportTouchMs      []float64
		renderMs, serializeMs, invmTotalMs                                       []float64
		firstAttemptHeld, preforkUsed                                             int
		successCount, totalCount                                                   int
		totalCostUSD                                                               float64
		lifecycle                                                                  string
	}

	m := make(map[key]*collector)
	order := []key{}

	for i := range samples {
		s := &samples[i]
		k := key{s.Region, s.Variant, s.Regime}
		c, exists := m[k]
		if !exists {
			c = &collector{lifecycle: s.Lifecycle}
			m[k] = c
			order = append(order, k)
		}
		c.totalCount++
		if !s.OK {
			continue
		}
		c.successCount++
		c.clientMs = append(c.clientMs, s.ClientMs)
		c.totalCostUSD += s.CostEstimate

		if p := s.Provisioner; p != nil {
			c.runMicrovmMs = append(c.runMicrovmMs, p.RunMicrovmMs)
			c.tokenMintMs = append(c.tokenMintMs, p.TokenMintMs)
			c.tokenOverlapMs = append(c.tokenOverlapMs, p.TokenOverlapMs)
			c.execRttMs = append(c.execRttMs, p.ExecRttMs)
			c.totalMs = append(c.totalMs, p.TotalMs)
			if p.FirstAttemptHeld {
				c.firstAttemptHeld++
			}
		}
		if iv := s.InVM; iv != nil {
			c.sinceRunHookMs = append(c.sinceRunHookMs, iv.SinceRunHookMs)
			c.dispatchMs = append(c.dispatchMs, iv.DispatchMs)
			c.forkMs = append(c.forkMs, iv.ForkMs)
			c.userCodeMs = append(c.userCodeMs, iv.UserCodeMs)
			c.firstImportTouchMs = append(c.firstImportTouchMs, iv.FirstImportTouchMs)
			c.renderMs = append(c.renderMs, iv.RenderMs)
			c.serializeMs = append(c.serializeMs, iv.SerializeMs)
			c.invmTotalMs = append(c.invmTotalMs, iv.TotalMs)
			if iv.PreforkUsed {
				c.preforkUsed++
			}
		}
	}

	out := make([]CellStats, 0, len(order))
	for _, k := range order {
		c := m[k]
		cs := CellStats{
			Region:             k.region,
			Variant:            k.variant,
			Regime:             k.regime,
			ClientMs:           computeStats(c.clientMs),
			RunMicrovmMs:       computeStats(c.runMicrovmMs),
			TokenMintMs:        computeStats(c.tokenMintMs),
			TokenOverlapMs:     computeStats(c.tokenOverlapMs),
			ExecRttMs:          computeStats(c.execRttMs),
			TotalMs:            computeStats(c.totalMs),
			SinceRunHookMs:     computeStats(c.sinceRunHookMs),
			DispatchMs:         computeStats(c.dispatchMs),
			ForkMs:             computeStats(c.forkMs),
			UserCodeMs:         computeStats(c.userCodeMs),
			FirstImportTouchMs: computeStats(c.firstImportTouchMs),
			RenderMs:           computeStats(c.renderMs),
			SerializeMs:        computeStats(c.serializeMs),
			InVMTotalMs:        computeStats(c.invmTotalMs),
			SuccessCount:       c.successCount,
			TotalCount:         c.totalCount,
			TotalCostUSD:       c.totalCostUSD,
		}
		if c.successCount > 0 {
			cs.FirstAttemptHeldRate = float64(c.firstAttemptHeld) / float64(c.successCount)
			cs.PreforkUsedRate = float64(c.preforkUsed) / float64(c.successCount)
		}
		out = append(out, cs)
	}
	return out
}

// Write persists the RunResult to results/<timestamp>.json and a flattened CSV.
// Returns the paths of the two files written.
func Write(dir string, rr *RunResult) (jsonPath, csvPath string, err error) {
	if err = os.MkdirAll(dir, 0o755); err != nil {
		return "", "", fmt.Errorf("mkdir %s: %w", dir, err)
	}

	ts := rr.Timestamp.UTC().Format("20060102T150405Z")
	jsonPath = filepath.Join(dir, ts+".json")
	csvPath = filepath.Join(dir, ts+".csv")

	// JSON
	data, err := json.MarshalIndent(rr, "", "  ")
	if err != nil {
		return "", "", fmt.Errorf("marshal JSON: %w", err)
	}
	if err = os.WriteFile(jsonPath, data, 0o644); err != nil {
		return "", "", fmt.Errorf("write JSON: %w", err)
	}

	// CSV — flattened sample rows
	f, err := os.Create(csvPath)
	if err != nil {
		return "", "", fmt.Errorf("create CSV: %w", err)
	}
	defer f.Close()

	w := csv.NewWriter(f)
	header := []string{
		"sampleIdx", "region", "variant", "regime", "lifecycle", "microvmId",
		"ok", "clientMs", "costEstimateUsd",
		// provisioner
		"lambdaCold", "runMicrovmMs", "tokenMintMs", "tokenOverlapMs",
		"execRttMs", "firstAttemptHeld", "execRetries", "provTotalMs",
		// invm
		"sinceRunHookMs", "dispatchMs", "forkMs", "preforkUsed",
		"userCodeMs", "firstImportTouchMs", "renderMs", "serializeMs", "invmTotalMs",
		"resumedSinceLastExec",
		"error",
	}
	if err = w.Write(header); err != nil {
		return "", "", fmt.Errorf("write CSV header: %w", err)
	}

	b2s := func(v bool) string {
		if v {
			return "true"
		}
		return "false"
	}
	f64 := func(v float64) string { return strconv.FormatFloat(v, 'f', 3, 64) }
	i2s := func(v int) string { return strconv.Itoa(v) }

	for _, s := range rr.Samples {
		var (
			lambdaCold, firstHeld, execRetries, provTotal        string
			runMs, tokenMint, tokenOverlap, execRtt              string
			sinceRun, dispatch, forkMs, prefork                  string
			userCode, firstImport, render, serial, invmTotal     string
			resumedSince                                          string
		)
		if p := s.Provisioner; p != nil {
			lambdaCold = b2s(p.LambdaCold)
			runMs = f64(p.RunMicrovmMs)
			tokenMint = f64(p.TokenMintMs)
			tokenOverlap = f64(p.TokenOverlapMs)
			execRtt = f64(p.ExecRttMs)
			firstHeld = b2s(p.FirstAttemptHeld)
			execRetries = i2s(p.ExecRetries)
			provTotal = f64(p.TotalMs)
		}
		if iv := s.InVM; iv != nil {
			sinceRun = f64(iv.SinceRunHookMs)
			dispatch = f64(iv.DispatchMs)
			forkMs = f64(iv.ForkMs)
			prefork = b2s(iv.PreforkUsed)
			userCode = f64(iv.UserCodeMs)
			firstImport = f64(iv.FirstImportTouchMs)
			render = f64(iv.RenderMs)
			serial = f64(iv.SerializeMs)
			invmTotal = f64(iv.TotalMs)
			resumedSince = b2s(iv.ResumedSinceLastExec)
		}
		row := []string{
			i2s(s.SampleIdx), s.Region, s.Variant, s.Regime, s.Lifecycle, s.MicrovmID,
			b2s(s.OK), f64(s.ClientMs), f64(s.CostEstimate),
			lambdaCold, runMs, tokenMint, tokenOverlap,
			execRtt, firstHeld, execRetries, provTotal,
			sinceRun, dispatch, forkMs, prefork,
			userCode, firstImport, render, serial, invmTotal,
			resumedSince,
			s.ErrorMsg,
		}
		if err = w.Write(row); err != nil {
			return "", "", fmt.Errorf("write CSV row: %w", err)
		}
	}
	w.Flush()
	if err = w.Error(); err != nil {
		return "", "", fmt.Errorf("flush CSV: %w", err)
	}

	return jsonPath, csvPath, nil
}

// PrintTable prints a human-readable summary of cell stats to stdout.
func PrintTable(stats []CellStats) {
	fmt.Printf("\n%-12s %-7s %-14s %8s %8s %8s %8s %8s %6s/%6s\n",
		"REGION", "VARIANT", "REGIME", "p50ms", "p95ms", "min", "max", "mean", "ok", "total")
	fmt.Println("---------------------------------------------------------------------------------------------")
	for _, cs := range stats {
		fmt.Printf("%-12s %-7s %-14s %8.1f %8.1f %8.1f %8.1f %8.1f %6d/%6d  cost=$%.5f\n",
			cs.Region, cs.Variant, cs.Regime,
			cs.ClientMs.P50, cs.ClientMs.P95,
			cs.ClientMs.Min, cs.ClientMs.Max, cs.ClientMs.Mean,
			cs.SuccessCount, cs.TotalCount, cs.TotalCostUSD)
	}
}
