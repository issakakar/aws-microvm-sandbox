package mvm

import (
	"context"
	"fmt"

	"github.com/aws/aws-sdk-go-v2/aws"
	awsconfig "github.com/aws/aws-sdk-go-v2/config"
	lmvm "github.com/aws/aws-sdk-go-v2/service/lambdamicrovms"
	lmvmtypes "github.com/aws/aws-sdk-go-v2/service/lambdamicrovms/types"
)

// API is the subset of the lambdamicrovms client the orchestrator uses. Declared
// as an interface so tests can substitute fakes.
type API interface {
	RunMicrovm(ctx context.Context, in *lmvm.RunMicrovmInput, opts ...func(*lmvm.Options)) (*lmvm.RunMicrovmOutput, error)
	CreateMicrovmAuthToken(ctx context.Context, in *lmvm.CreateMicrovmAuthTokenInput, opts ...func(*lmvm.Options)) (*lmvm.CreateMicrovmAuthTokenOutput, error)
	SuspendMicrovm(ctx context.Context, in *lmvm.SuspendMicrovmInput, opts ...func(*lmvm.Options)) (*lmvm.SuspendMicrovmOutput, error)
	TerminateMicrovm(ctx context.Context, in *lmvm.TerminateMicrovmInput, opts ...func(*lmvm.Options)) (*lmvm.TerminateMicrovmOutput, error)
}

// NewAPI builds a lambdamicrovms client for the given region using the default
// credential chain (CONTRACTS / API-FACTS Go client construction).
func NewAPI(ctx context.Context, region string) (API, error) {
	cfg, err := awsconfig.LoadDefaultConfig(ctx, awsconfig.WithRegion(region))
	if err != nil {
		return nil, fmt.Errorf("load aws config: %w", err)
	}
	return lmvm.NewFromConfig(cfg), nil
}

// authTokenHeaderKey is the map key returned by CreateMicrovmAuthToken; its value
// is the X-aws-proxy-auth header value (API-FACTS).
const authTokenHeaderKey = "X-aws-proxy-auth"

// authTokenExpirationMinutes is the token TTL (CONTRACTS §G; max is 60).
const authTokenExpirationMinutes int32 = 30

// allPortsSpec is the single-element allowedPorts union granting all ports
// (CONTRACTS §G / API-FACTS).
func allPortsSpec() []lmvmtypes.PortSpecification {
	return []lmvmtypes.PortSpecification{
		&lmvmtypes.PortSpecificationMemberAllPorts{Value: lmvmtypes.Unit{}},
	}
}

// runInput assembles the RunMicrovmInput for a cold create (CONTRACTS §G).
// clientToken is the idempotency key.
func runInput(cfg Config, imageArn string, p Preset, runHookPayload, clientToken string) *lmvm.RunMicrovmInput {
	in := &lmvm.RunMicrovmInput{
		ImageIdentifier:          aws.String(imageArn),
		MaximumDurationInSeconds: aws.Int32(p.MaximumDurationInSeconds),
		RunHookPayload:           aws.String(runHookPayload),
		ClientToken:              aws.String(clientToken),
		IdlePolicy: &lmvmtypes.IdlePolicy{
			AutoResumeEnabled:        aws.Bool(p.AutoResumeEnabled),
			MaxIdleDurationSeconds:   aws.Int32(p.MaxIdleDurationSeconds),
			SuspendedDurationSeconds: aws.Int32(p.SuspendedDurationSeconds),
		},
	}
	// executionRoleArn is OPTIONAL per the GA API (the getting-started run-microvm
	// example omits it). Only set it when configured, so an empty EXEC_ROLE_ARN
	// does not produce an invalid-ARN error and we can still launch (and add the
	// role later for in-VM CloudWatch Logs).
	if cfg.ExecRoleArn != "" {
		in.ExecutionRoleArn = aws.String(cfg.ExecRoleArn)
	}
	if cfg.IngressConnectorArn != "" {
		in.IngressNetworkConnectors = []string{cfg.IngressConnectorArn}
	}
	if cfg.EgressConnectorArn != "" {
		in.EgressNetworkConnectors = []string{cfg.EgressConnectorArn}
	}
	// Stream the in-VM manager's logs so the cold-create timeline (restore vs
	// boot, /run→/exec gap, PENDING→RUNNING) is measurable from the VM side. The
	// clientToken is the per-run idempotency key, so it makes a stable, unique
	// log-stream name to correlate a run with its trail.
	if cfg.MicrovmLogGroup != "" {
		in.Logging = &lmvmtypes.LoggingMemberCloudWatch{Value: lmvmtypes.CloudWatchLogging{
			LogGroup:  aws.String(cfg.MicrovmLogGroup),
			LogStream: aws.String("run-" + clientToken),
		}}
	}
	return in
}
