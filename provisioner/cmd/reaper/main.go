// Command reaper is an EventBridge-triggered Lambda that terminates leaked
// bench microVMs. It lists microVMs, keeps only ours (image ARN under the
// microvm-bench image namespace per CONTRACTS §D), and terminates any older than
// REAP_TTL_SECONDS (default 900 = 15 min). Insurance against leaks.
//
// Tag-based filtering (Project=microvm-bench) is NOT used: RunMicrovmInput has no
// Tags field in the GA SDK, so running microVMs carry no controllable tag; the
// reliable signal on every ListMicrovms item is the image ARN, which is created
// per-region as microvm-image:microvm-bench-<variant> (CONTRACTS §D).
package main

import (
	"context"
	"log"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/aws/aws-lambda-go/events"
	"github.com/aws/aws-lambda-go/lambda"
	"github.com/aws/aws-sdk-go-v2/aws"
	awsconfig "github.com/aws/aws-sdk-go-v2/config"
	lmvm "github.com/aws/aws-sdk-go-v2/service/lambdamicrovms"
	lmvmtypes "github.com/aws/aws-sdk-go-v2/service/lambdamicrovms/types"
)

// imageMarker identifies our bench microVM images in their ARN
// (arn:aws:lambda:<region>:<acct>:microvm-image:microvm-bench-<variant>).
const imageMarker = "microvm-image:microvm-bench-"

// defaultTTLSeconds is the reap age threshold when REAP_TTL_SECONDS is unset.
const defaultTTLSeconds int64 = 900

// reaperAPI is the subset of the lambdamicrovms client the reaper uses.
type reaperAPI interface {
	ListMicrovms(ctx context.Context, in *lmvm.ListMicrovmsInput, opts ...func(*lmvm.Options)) (*lmvm.ListMicrovmsOutput, error)
	TerminateMicrovm(ctx context.Context, in *lmvm.TerminateMicrovmInput, opts ...func(*lmvm.Options)) (*lmvm.TerminateMicrovmOutput, error)
}

func ttlSeconds() int64 {
	if v := os.Getenv("REAP_TTL_SECONDS"); v != "" {
		if n, err := strconv.ParseInt(v, 10, 64); err == nil && n > 0 {
			return n
		}
	}
	return defaultTTLSeconds
}

// reap lists, filters, and terminates stale bench microVMs. Returns the count
// terminated.
func reap(ctx context.Context, api reaperAPI, ttl time.Duration, now time.Time) (int, error) {
	cutoff := now.Add(-ttl)
	terminated := 0
	var nextToken *string

	for {
		out, err := api.ListMicrovms(ctx, &lmvm.ListMicrovmsInput{NextToken: nextToken})
		if err != nil {
			return terminated, err
		}
		for _, it := range out.Items {
			if !isOurs(it) || !isReapable(it.State) {
				continue
			}
			if it.StartedAt == nil || it.StartedAt.After(cutoff) {
				continue
			}
			id := aws.ToString(it.MicrovmId)
			if _, err := api.TerminateMicrovm(ctx, &lmvm.TerminateMicrovmInput{MicrovmIdentifier: aws.String(id)}); err != nil {
				log.Printf("reaper: terminate %s failed (continuing): %v", id, err)
				continue
			}
			log.Printf("reaper: terminated %s (started %s, image %s)", id, it.StartedAt.Format(time.RFC3339), aws.ToString(it.ImageArn))
			terminated++
		}
		if out.NextToken == nil {
			break
		}
		nextToken = out.NextToken
	}
	return terminated, nil
}

// isOurs reports whether a microVM was launched from a bench image.
func isOurs(it lmvmtypes.MicrovmItem) bool {
	return strings.Contains(aws.ToString(it.ImageArn), imageMarker)
}

// isReapable excludes microVMs already on their way out (TerminateMicrovm on a
// TERMINATING/TERMINATED vm is wasteful / errors).
func isReapable(s lmvmtypes.MicrovmState) bool {
	switch s {
	case lmvmtypes.MicrovmStateTerminating, lmvmtypes.MicrovmStateTerminated:
		return false
	default:
		return true
	}
}

func handler(ctx context.Context, _ events.CloudWatchEvent) error {
	region := os.Getenv("REGION")
	if region == "" {
		log.Printf("reaper: REGION env var not set")
		return nil
	}
	cfg, err := awsconfig.LoadDefaultConfig(ctx, awsconfig.WithRegion(region))
	if err != nil {
		return err
	}
	api := lmvm.NewFromConfig(cfg)
	ttl := time.Duration(ttlSeconds()) * time.Second
	n, err := reap(ctx, api, ttl, time.Now())
	if err != nil {
		log.Printf("reaper: list/terminate error after reaping %d: %v", n, err)
		return err
	}
	log.Printf("reaper: reaped %d microVM(s) older than %s in %s", n, ttl, region)
	return nil
}

func main() {
	lambda.Start(handler)
}
