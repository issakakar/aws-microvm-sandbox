// Package client implements an HTTP client for the provisioner Function URL
// using the §A API defined in CONTRACTS.md.
package client

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	v4 "github.com/aws/aws-sdk-go-v2/aws/signer/v4"
	awsconfig "github.com/aws/aws-sdk-go-v2/config"
)

// ProvisionerRequest matches §A of CONTRACTS.md exactly.
type ProvisionerRequest struct {
	Action    string `json:"action"`              // "run" | "reuse" | "suspend" | "terminate"
	Variant   string `json:"variant"`             // "base" | "mpl" | "sci"
	Lifecycle string `json:"lifecycle"`           // "ephemeral" | "idle30" | "idle60" | "max5" | "max10"
	Code      string `json:"code,omitempty"`      // required for run|reuse
	MicrovmID string `json:"microvmId,omitempty"` // required for reuse|suspend|terminate
	Endpoint  string `json:"endpoint,omitempty"`  // optional cache for reuse
	WantImage bool   `json:"wantImage"`
	TimeoutMs int    `json:"timeoutMs,omitempty"`
}

// ProvisionerResponse matches §A of CONTRACTS.md exactly.
type ProvisionerResponse struct {
	OK              bool         `json:"ok"`
	MicrovmID       string       `json:"microvmId"`
	Endpoint        string       `json:"endpoint"`
	State           string       `json:"state"`
	Regime          string       `json:"regime"`
	Result          *ExecResult  `json:"result"`
	Timings         *TimingBlock `json:"timings"`
	CostEstimateUSD float64      `json:"costEstimateUsd"`
	Error           *string      `json:"error"`
}

// ExecResult is the result sub-object from §A.
type ExecResult struct {
	OK          bool    `json:"ok"`
	Stdout      string  `json:"stdout"`
	Stderr      string  `json:"stderr"`
	ImagePngB64 *string `json:"imagePngB64"`
	Error       *string `json:"error"`
}

// TimingBlock holds provisioner + in-VM timings from §A.
type TimingBlock struct {
	Provisioner *ProvisionerTimings `json:"provisioner"`
	InVM        *InVMTimings        `json:"invm"`
}

// ProvisionerTimings maps to §A provisioner timings.
type ProvisionerTimings struct {
	LambdaCold       bool    `json:"lambdaCold"`
	RunMicrovmMs     float64 `json:"runMicrovmMs"`
	TokenMintMs      float64 `json:"tokenMintMs"`
	TokenOverlapMs   float64 `json:"tokenOverlapMs"`
	ExecRttMs        float64 `json:"execRttMs"`
	FirstAttemptHeld bool    `json:"firstAttemptHeld"`
	ExecRetries      int     `json:"execRetries"`
	TotalMs          float64 `json:"totalMs"`
}

// InVMTimings maps to §A invm timings.
type InVMTimings struct {
	SinceRunHookMs       float64 `json:"sinceRunHookMs"`
	DispatchMs           float64 `json:"dispatchMs"`
	ForkMs               float64 `json:"forkMs"`
	PreforkUsed          bool    `json:"preforkUsed"`
	UserCodeMs           float64 `json:"userCodeMs"`
	FirstImportTouchMs   float64 `json:"firstImportTouchMs"`
	RenderMs             float64 `json:"renderMs"`
	SerializeMs          float64 `json:"serializeMs"`
	TotalMs              float64 `json:"totalMs"`
	ResumedSinceLastExec bool    `json:"resumedSinceLastExec"`
}

// Client is a thin HTTP client for one provisioner Function URL. The Function URL
// uses authorization_type=AWS_IAM (the account's Org SCP blocks public auth-NONE
// URLs), so every request is SigV4-signed for service "lambda" in BaseURL's region.
type Client struct {
	BaseURL    string
	Region     string
	HTTPClient *http.Client
	creds      aws.CredentialsProvider
	signer     *v4.Signer
	initErr    error
}

// New creates a Client for the given Function URL base (no trailing slash).
func New(baseURL, region string) *Client {
	return NewWithTimeout(baseURL, region, 30*time.Second)
}

// NewWithTimeout creates a Client with a custom HTTP timeout. region is the
// AWS region of the Function URL, used for SigV4 signing.
func NewWithTimeout(baseURL, region string, timeout time.Duration) *Client {
	c := &Client{
		BaseURL:    baseURL,
		Region:     region,
		HTTPClient: &http.Client{Timeout: timeout},
		signer:     v4.NewSigner(),
	}
	cfg, err := awsconfig.LoadDefaultConfig(context.Background(), awsconfig.WithRegion(region))
	if err != nil {
		c.initErr = fmt.Errorf("load aws config for SigV4: %w", err)
	} else {
		c.creds = cfg.Credentials
	}
	return c
}

// Do sends one request to POST / and returns the response with wall-clock timing.
// clientMs is the round-trip time measured by the caller using time.Now().
func (c *Client) Do(ctx context.Context, req ProvisionerRequest) (*ProvisionerResponse, time.Duration, error) {
	body, err := json.Marshal(req)
	if err != nil {
		return nil, 0, fmt.Errorf("marshal request: %w", err)
	}

	if c.initErr != nil {
		return nil, 0, c.initErr
	}

	httpReq, err := http.NewRequestWithContext(ctx, http.MethodPost, c.BaseURL+"/", bytes.NewReader(body))
	if err != nil {
		return nil, 0, fmt.Errorf("create request: %w", err)
	}
	httpReq.Header.Set("Content-Type", "application/json")
	httpReq.Header.Set("Accept", "application/json")

	// SigV4-sign for the AWS_IAM Function URL (service "lambda", BaseURL's region).
	cr, err := c.creds.Retrieve(ctx)
	if err != nil {
		return nil, 0, fmt.Errorf("retrieve aws creds: %w", err)
	}
	payloadHash := sha256.Sum256(body)
	if err := c.signer.SignHTTP(ctx, cr, httpReq, hex.EncodeToString(payloadHash[:]), "lambda", c.Region, time.Now()); err != nil {
		return nil, 0, fmt.Errorf("sigv4 sign: %w", err)
	}

	start := time.Now()
	resp, err := c.HTTPClient.Do(httpReq)
	elapsed := time.Since(start)
	if err != nil {
		return nil, elapsed, fmt.Errorf("http do: %w", err)
	}
	defer resp.Body.Close()

	rawBody, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, elapsed, fmt.Errorf("read body: %w", err)
	}

	// The provisioner returns the §A-shaped body even on failure (HTTP 502 with
	// {ok:false,error,...,timings}). Parse the body regardless of status so a
	// failed-but-timed run keeps its timings; only a non-JSON body (e.g. a 403
	// auth page from the Function URL itself) is a genuine transport/auth error.
	var out ProvisionerResponse
	if jerr := json.Unmarshal(rawBody, &out); jerr != nil {
		return nil, elapsed, fmt.Errorf("provisioner HTTP %d (non-JSON body): %s", resp.StatusCode, string(rawBody))
	}
	return &out, elapsed, nil
}
