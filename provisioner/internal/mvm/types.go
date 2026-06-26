// Package mvm orchestrates the AWS Lambda MicroVMs lifecycle for one provisioner
// request: RunMicrovm, CreateMicrovmAuthToken (concurrent), and the send-and-hold
// POST /exec data-plane call. Field names and the request/response wire shapes
// match docs/CONTRACTS.md §A and §B byte-for-byte.
package mvm

// Action is the requested lifecycle action (CONTRACTS §A).
type Action string

const (
	ActionRun       Action = "run"
	ActionReuse     Action = "reuse"
	ActionSuspend   Action = "suspend"
	ActionTerminate Action = "terminate"
)

// Regime labels the measured launch regime (CONTRACTS §A response).
const (
	RegimeColdCreate = "cold-create"
	RegimeWarmResume = "warm-resume"
	RegimeHot        = "hot"
	RegimeControl    = "control"
)

// Request is the browser → provisioner JSON body (CONTRACTS §A request).
type Request struct {
	Action    Action `json:"action"`
	Variant   string `json:"variant"`
	Lifecycle string `json:"lifecycle"`
	Code      string `json:"code"`
	MicrovmID string `json:"microvmId"`
	Endpoint  string `json:"endpoint"`
	WantImage bool   `json:"wantImage"`
	TimeoutMs int    `json:"timeoutMs"`
}

// ProvisionerTimings is the Go-monotonic timing block (CONTRACTS §A).
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

// InVMTimings mirrors the worker's CLOCK_MONOTONIC block (CONTRACTS §A/§B).
// Pointer so it can be null for control actions.
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

// Timings is the merged timing block (CONTRACTS §A response).
type Timings struct {
	Provisioner ProvisionerTimings `json:"provisioner"`
	InVM        *InVMTimings       `json:"invm"`
}

// ExecResult is the worker's exec payload (CONTRACTS §A response.result / §B).
type ExecResult struct {
	OK          bool    `json:"ok"`
	Stdout      string  `json:"stdout"`
	Stderr      string  `json:"stderr"`
	ImagePngB64 *string `json:"imagePngB64"`
	Error       *string `json:"error"`
}

// Response is the provisioner → browser JSON body (CONTRACTS §A response).
type Response struct {
	OK              bool        `json:"ok"`
	MicrovmID       string      `json:"microvmId"`
	Endpoint        string      `json:"endpoint"`
	State           string      `json:"state"`
	Regime          string      `json:"regime"`
	Result          *ExecResult `json:"result"`
	Timings         Timings     `json:"timings"`
	CostEstimateUsd float64     `json:"costEstimateUsd"`
	Error           *string     `json:"error"`
}

// execRequest is the provisioner → worker body (CONTRACTS §B request).
type execRequest struct {
	Code      string `json:"code"`
	WantImage bool   `json:"wantImage"`
	TimeoutMs int    `json:"timeoutMs"`
}

// execResponse is the worker → provisioner body (CONTRACTS §B response).
type execResponse struct {
	OK          bool         `json:"ok"`
	Stdout      string       `json:"stdout"`
	Stderr      string       `json:"stderr"`
	ImagePngB64 *string      `json:"imagePngB64"`
	Error       *string      `json:"error"`
	Timings     *InVMTimings `json:"timings"`
}
