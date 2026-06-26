package mvm

import (
	"fmt"
	"os"
)

// Config holds the environment-derived settings the orchestrator needs
// (CONTRACTS §E env vars).
type Config struct {
	Region              string
	ResultsTable        string
	ExecRoleArn         string
	IngressConnectorArn string
	EgressConnectorArn  string
	ImageArnByVariant   map[string]string // base/mpl/sci → image ARN
	ExecPort            string
	// MicrovmLogGroup, when set, makes RunMicrovm stream the in-VM manager's
	// CloudWatch logs (the /run, /exec, restore-vs-boot trail) so cold-create
	// timing can be measured from the VM side. Requires the exec role to carry
	// logs perms on this group (it does: /microvm-bench/* — global/main.tf).
	MicrovmLogGroup string
}

// LoadConfig reads the provisioner env vars (CONTRACTS §E). REGION is required;
// the rest are optional at parse time so the handler can still return a
// structured error for control actions even with partial config.
func LoadConfig() (Config, error) {
	c := Config{
		Region:              os.Getenv("REGION"),
		ResultsTable:        os.Getenv("RESULTS_TABLE"),
		ExecRoleArn:         os.Getenv("EXEC_ROLE_ARN"),
		IngressConnectorArn: os.Getenv("INGRESS_CONNECTOR_ARN"),
		EgressConnectorArn:  os.Getenv("EGRESS_CONNECTOR_ARN"),
		ExecPort:            os.Getenv("EXEC_PORT"),
		MicrovmLogGroup:     os.Getenv("MICROVM_LOG_GROUP"),
		ImageArnByVariant: map[string]string{
			"base": os.Getenv("IMAGE_ARN_BASE"),
			"mpl":  os.Getenv("IMAGE_ARN_MPL"),
			"sci":  os.Getenv("IMAGE_ARN_SCI"),
		},
	}
	if c.ExecPort == "" {
		c.ExecPort = "8080"
	}
	if c.Region == "" {
		return c, fmt.Errorf("REGION env var is required")
	}
	// Default the in-VM log group to the Terraform-created one for this region
	// so runtime logging is on by default (the bench wants the VM-side trail).
	if c.MicrovmLogGroup == "" {
		c.MicrovmLogGroup = fmt.Sprintf("/microvm-bench/microvm/%s", c.Region)
	}
	return c, nil
}

// ImageArn returns the image ARN for a variant, or an error for unknown/empty.
func (c Config) ImageArn(variant string) (string, error) {
	arn, ok := c.ImageArnByVariant[variant]
	if !ok {
		return "", fmt.Errorf("unknown variant %q", variant)
	}
	if arn == "" {
		return "", fmt.Errorf("no image ARN configured for variant %q (set IMAGE_ARN_%s)", variant, variant)
	}
	return arn, nil
}

// Preset is the RunMicrovm idlePolicy + maximumDuration mapping for a lifecycle
// preset (CONTRACTS §G).
type Preset struct {
	MaxIdleDurationSeconds   int32
	SuspendedDurationSeconds int32
	AutoResumeEnabled        bool
	MaximumDurationInSeconds int32
	// TerminateAfterExec is true only for the ephemeral preset.
	TerminateAfterExec bool
}

// presets maps lifecycle name → Preset (CONTRACTS §G).
//
// EMPIRICAL API CONSTRAINT (verified live against RunMicrovm, GA 2026-06):
// idlePolicy.maxIdleDurationSeconds must be >= 60. The original ephemeral/idle30
// values of 30 were rejected with a ValidationException. The floor is therefore
// 60, so a true sub-60s idle threshold is NOT expressible — `idle30` now uses the
// 60s floor (its key is retained for the frozen contract / UI labels; it behaves
// like idle60). ephemeral terminates right after exec, so its idle value is moot
// but must still be valid.
var presets = map[string]Preset{
	"ephemeral": {MaxIdleDurationSeconds: 60, SuspendedDurationSeconds: 0, AutoResumeEnabled: false, MaximumDurationInSeconds: 120, TerminateAfterExec: true},
	"idle30":    {MaxIdleDurationSeconds: 60, SuspendedDurationSeconds: 300, AutoResumeEnabled: true, MaximumDurationInSeconds: 600},
	"idle60":    {MaxIdleDurationSeconds: 60, SuspendedDurationSeconds: 300, AutoResumeEnabled: true, MaximumDurationInSeconds: 600},
	"max5":      {MaxIdleDurationSeconds: 60, SuspendedDurationSeconds: 240, AutoResumeEnabled: true, MaximumDurationInSeconds: 300},
	"max10":     {MaxIdleDurationSeconds: 120, SuspendedDurationSeconds: 480, AutoResumeEnabled: true, MaximumDurationInSeconds: 600},
}

// PresetFor returns the Preset for a lifecycle name, defaulting to ephemeral
// (safest cost profile) for unknown names.
func PresetFor(lifecycle string) (Preset, error) {
	p, ok := presets[lifecycle]
	if !ok {
		return Preset{}, fmt.Errorf("unknown lifecycle preset %q", lifecycle)
	}
	return p, nil
}

// DeriveEndpoint builds the deterministic data-plane host for a microVM
// (CONTRACTS §A / API-FACTS endpoint data-plane). No scheme, no path.
func DeriveEndpoint(microvmID, region string) string {
	return fmt.Sprintf("%s.lambda-microvm.%s.on.aws", microvmID, region)
}
