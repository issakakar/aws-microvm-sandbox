// Command harness is the CLI for driving the microvm-bench provisioner.
//
// Subcommands:
//
//	run      — execute the benchmark matrix and collect latency stats.
//	estimate — offline cost math, no AWS calls.
//	reap     — terminate stray microVMs.
package main

import (
	"context"
	"fmt"
	"os"
	"strings"
	"time"

	"github.com/spf13/cobra"

	"microvm-bench/harness/internal/client"
	"microvm-bench/harness/internal/config"
	"microvm-bench/harness/internal/cost"
	"microvm-bench/harness/internal/results"
	"microvm-bench/harness/internal/runner"
)

func main() {
	if err := rootCmd().Execute(); err != nil {
		os.Exit(1)
	}
}

// ---------- shared flags ----------

type globalFlags struct {
	use1URL    string
	usw2URL    string
	configFile string
	budgetUSD  float64
	dryRun     bool
	yes        bool
}

// ---------- root ----------

func rootCmd() *cobra.Command {
	gf := &globalFlags{}

	root := &cobra.Command{
		Use:   "harness",
		Short: "microvm-bench test harness — drive the provisioner, collect latency stats",
		Long: `harness drives the deployed provisioner Function URLs over HTTP to collect
latency stats across regimes (cold-create, hot, warm-resume).

Read Function URLs from --use1-url / --usw2-url or harness/urls.json.
Always run 'estimate' first to check projected cost before 'run'.`,
		SilenceUsage:  true,
		SilenceErrors: false,
	}

	root.PersistentFlags().StringVar(&gf.use1URL, "use1-url", "", "Provisioner Function URL for us-east-1")
	root.PersistentFlags().StringVar(&gf.usw2URL, "usw2-url", "", "Provisioner Function URL for us-west-2")
	root.PersistentFlags().StringVar(&gf.configFile, "config", "urls.json", "Path to JSON config with use1_url / usw2_url")
	root.PersistentFlags().Float64Var(&gf.budgetUSD, "budget-usd", 2.00, "Refuse to run if estimated cost exceeds this (pass --yes to override)")
	root.PersistentFlags().BoolVar(&gf.dryRun, "dry-run", false, "Plan only — print what would happen, make no AWS calls")
	root.PersistentFlags().BoolVar(&gf.yes, "yes", false, "Skip budget guard (use with caution)")

	root.AddCommand(runCmd(gf))
	root.AddCommand(estimateCmd())
	root.AddCommand(reapCmd(gf))

	return root
}

// ---------- run ----------

func runCmd(gf *globalFlags) *cobra.Command {
	var (
		regions   []string
		variants  []string
		regimes   []string
		lifecycle string
		samples   int
		outDir    string
	)

	cmd := &cobra.Command{
		Use:   "run",
		Short: "Run the benchmark matrix and write results/<timestamp>.json + .csv",
		Long: `Run iterates (region x variant x regime) x N samples.

Regimes:
  cold-create  — action=run, lifecycle=ephemeral; each VM terminates itself.
  hot          — one cold-create then N-1 action=reuse (already RUNNING).
  warm-resume  — cold-create, then suspend+reuse each sample (SUSPENDED→RUNNING).

The harness always terminates any microVM it created when done.
RunMicrovm is throttled to <=5/s (sequential with a 200 ms floor).`,
		RunE: func(cmd *cobra.Command, args []string) error {
			return doRun(cmd.Context(), gf, regions, variants, regimes, lifecycle, samples, outDir)
		},
	}

	cmd.Flags().StringSliceVar(&regions, "regions", []string{"us-east-1", "us-west-2"},
		"Comma-separated regions to test")
	cmd.Flags().StringSliceVar(&variants, "variants", []string{"base", "mpl", "sci"},
		"Comma-separated image variants: base, mpl, sci")
	cmd.Flags().StringSliceVar(&regimes, "regimes", []string{"cold-create", "hot", "warm-resume"},
		"Comma-separated regimes: cold-create, hot, warm-resume")
	cmd.Flags().StringVar(&lifecycle, "lifecycle", "",
		"Override lifecycle preset (default: auto per regime: cold-create→ephemeral, else idle30)")
	cmd.Flags().IntVar(&samples, "samples", 3, "Samples per (region x variant x regime) cell")
	cmd.Flags().StringVar(&outDir, "out-dir", "results", "Directory to write JSON + CSV results")

	return cmd
}

func doRun(ctx context.Context, gf *globalFlags, regions, variants, regimes []string, lifecycle string, samples int, outDir string) error {
	// 1. Load URL config.
	cfg, err := config.Load(gf.use1URL, gf.usw2URL, gf.configFile)
	if err != nil {
		return err
	}

	// 2. Compute cost estimate upfront.
	est := cost.Estimate(cost.Params{
		Regions:        regions,
		Variants:       variants,
		Regimes:        regimes,
		SamplesPerCell: samples,
		RunDurationSec: 3.0, // conservative wall-clock per exec
		BaselineGB:     0,   // use per-variant defaults
	})

	fmt.Println("\n=== Pre-run cost estimate ===")
	fmt.Print(cost.FormatTable(est))
	fmt.Printf("\nEstimated total: $%.5f\n", est.TotalUSD)

	// 3. Budget guard.
	if est.TotalUSD > gf.budgetUSD && !gf.yes {
		return fmt.Errorf("estimated cost $%.5f exceeds --budget-usd $%.2f; pass --yes to override",
			est.TotalUSD, gf.budgetUSD)
	}

	if gf.dryRun {
		fmt.Println("\n[dry-run] No AWS calls will be made.")
	}

	// 4. Run the matrix.
	p := runner.Params{
		Regions:   regions,
		Variants:  variants,
		Regimes:   regimes,
		Lifecycle: lifecycle,
		Samples:   samples,
		DryRun:    gf.dryRun,
		URLForRegion: func(region string) (string, error) {
			return cfg.URLForRegion(region)
		},
		Logger: func(format string, args ...any) {
			fmt.Printf("[harness] "+format+"\n", args...)
		},
	}

	start := time.Now()
	allSamples, runErr := runner.Run(ctx, p)
	elapsed := time.Since(start)

	fmt.Printf("\n[harness] matrix done in %s (%d samples)\n", elapsed.Round(time.Millisecond), len(allSamples))

	if len(allSamples) == 0 {
		if runErr != nil {
			return runErr
		}
		fmt.Println("[harness] no samples collected")
		return nil
	}

	// 5. Compute stats + write results.
	cellStats := results.Aggregate(allSamples)
	results.PrintTable(cellStats)

	totalCost := 0.0
	for _, s := range allSamples {
		totalCost += s.CostEstimate
	}

	rr := &results.RunResult{
		Timestamp:    time.Now().UTC(),
		Samples:      allSamples,
		CellStats:    cellStats,
		TotalCostUSD: totalCost,
	}

	if !gf.dryRun {
		jsonPath, csvPath, writeErr := results.Write(outDir, rr)
		if writeErr != nil {
			fmt.Fprintf(os.Stderr, "[harness] warning: failed to write results: %v\n", writeErr)
		} else {
			fmt.Printf("\n[harness] results written:\n  JSON: %s\n  CSV:  %s\n", jsonPath, csvPath)
		}
	}

	return runErr
}

// ---------- estimate ----------

func estimateCmd() *cobra.Command {
	var (
		regions    []string
		variants   []string
		regimes    []string
		samples    int
		durationS  float64
		baselineGB float64
	)

	cmd := &cobra.Command{
		Use:   "estimate",
		Short: "Offline cost math — no AWS calls",
		Long: `Estimate projected cost for the given matrix using API-FACTS pricing constants.

Pricing is us-east-1 ARM64. us-west-2 is the same tier.
Compute = N * duration * (vCPU * $0.0000276944/s + memGB * $0.0000036667/s)
SnapRead = N * memGB * $0.00155/GB  (cold-create + warm-resume)
SnapWrite = N * memGB * $0.0038/GB  (warm-resume: one suspend per sample)`,
		RunE: func(cmd *cobra.Command, args []string) error {
			est := cost.Estimate(cost.Params{
				Regions:        regions,
				Variants:       variants,
				Regimes:        regimes,
				SamplesPerCell: samples,
				RunDurationSec: durationS,
				BaselineGB:     baselineGB,
			})
			fmt.Println(cost.FormatTable(est))
			fmt.Printf("Estimated total: $%.6f\n", est.TotalUSD)
			return nil
		},
	}

	cmd.Flags().StringSliceVar(&regions, "regions", []string{"us-east-1", "us-west-2"}, "Regions")
	cmd.Flags().StringSliceVar(&variants, "variants", []string{"base", "mpl", "sci"}, "Variants")
	cmd.Flags().StringSliceVar(&regimes, "regimes", []string{"cold-create", "hot", "warm-resume"}, "Regimes")
	cmd.Flags().IntVar(&samples, "samples", 3, "Samples per cell")
	cmd.Flags().Float64Var(&durationS, "duration-s", 3.0, "Average per-run wall-clock seconds")
	cmd.Flags().Float64Var(&baselineGB, "baseline-gb", 0, "Override baseline memory GB (0 = per-variant default)")

	return cmd
}

// ---------- reap ----------

func reapCmd(gf *globalFlags) *cobra.Command {
	var microvmIDs []string

	cmd := &cobra.Command{
		Use:   "reap [microvmId...]",
		Short: "Terminate specified microVMs, or print the manual aws CLI to list+kill bench VMs",
		Long: `Reap terminates the provided microvmIds (action=terminate via the provisioner).

If no IDs are given, it prints the manual 'aws lambda-microvms list-microvms' CLI
command to inspect and reap bench microVMs (identified by their image ARN).

Example:
  harness reap mvm-abc123 mvm-def456
  harness --dry-run reap mvm-abc123`,
		RunE: func(cmd *cobra.Command, args []string) error {
			// Positional args are also accepted as microvmIds.
			ids := append(microvmIDs, args...)
			return doReap(cmd.Context(), gf, ids)
		},
	}

	cmd.Flags().StringSliceVar(&microvmIDs, "ids", nil, "Comma-separated microvmIds to terminate")

	return cmd
}

func doReap(ctx context.Context, gf *globalFlags, ids []string) error {
	if len(ids) == 0 {
		printReapManual()
		return nil
	}

	cfg, err := config.Load(gf.use1URL, gf.usw2URL, gf.configFile)
	if err != nil {
		return err
	}

	// Try both regions for each ID (we don't know which region the VM is in from the ID alone).
	regions := []string{"us-east-1", "us-west-2"}

	for _, id := range ids {
		id = strings.TrimSpace(id)
		if id == "" {
			continue
		}
		fmt.Printf("[reap] terminating %s ...", id)
		if gf.dryRun {
			fmt.Printf(" [dry-run skipped]\n")
			continue
		}

		terminated := false
		for _, region := range regions {
			url, urlErr := cfg.URLForRegion(region)
			if urlErr != nil {
				continue
			}
			c := client.NewWithTimeout(url, region, 30*time.Second)
			req := client.ProvisionerRequest{
				Action:    "terminate",
				MicrovmID: id,
				// variant/lifecycle don't matter for terminate
				Variant:   "base",
				Lifecycle: "ephemeral",
			}
			resp, _, doErr := c.Do(ctx, req)
			if doErr == nil && resp != nil && resp.OK {
				fmt.Printf(" OK (region=%s)\n", region)
				terminated = true
				break
			}
		}
		if !terminated {
			fmt.Printf(" FAILED (check IDs / URLs)\n")
		}
	}
	return nil
}

func printReapManual() {
	fmt.Println("No microvmIds provided. To manually inspect and reap bench microVMs:")
	fmt.Println()
	fmt.Println("  # List bench microVMs in us-east-1 (identified by image-ARN marker —")
	fmt.Println("  # RunMicrovm has no Tags field, so tag filtering finds nothing):")
	fmt.Println("  aws lambda-microvms list-microvms \\")
	fmt.Println("    --profile microvm-bench --region us-east-1 --output json \\")
	fmt.Println("  | jq -r '(.items // .microvms // [])[]")
	fmt.Println("      | select(((.imageArn // .ImageArn) // \"\") | contains(\"microvm-image:microvm-bench-\"))")
	fmt.Println("      | (.microvmId // .MicrovmId)'")
	fmt.Println()
	fmt.Println("  # Terminate one:")
	fmt.Println("  aws lambda-microvms terminate-microvm \\")
	fmt.Println("    --profile microvm-bench --region us-east-1 \\")
	fmt.Println("    --microvm-identifier <microvmId>")
	fmt.Println()
	fmt.Println("  # Or sweep everything: bash scripts/reap.sh   (repeat/auto for us-west-2).")
	fmt.Println()
	fmt.Println("Or run 'harness reap <id1> <id2> ...' to terminate via the provisioner.")
}
