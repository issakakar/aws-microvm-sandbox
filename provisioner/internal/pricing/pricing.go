// Package pricing computes a best-effort per-run cost estimate for a microVM
// invocation. Constants are taken verbatim from docs/API-FACTS.md §pricing
// (us-east-1, ARM). These are estimates for the bench dashboard, not billing.
package pricing

// Pricing constants (us-east-1, ARM64). Source: API-FACTS.md.
const (
	// VCPUPerSec is the price per vCPU-second.
	VCPUPerSec = 0.0000276944
	// MemPerGBSec is the price per GB-second of baseline memory.
	MemPerGBSec = 0.0000036667
	// SnapshotWritePerGB is the suspend (snapshot WRITE) price per GB.
	SnapshotWritePerGB = 0.0038
	// SnapshotReadPerGB is the launch+resume (snapshot READ) price per GB.
	SnapshotReadPerGB = 0.00155
	// SnapshotStoragePerGBMonth is the snapshot storage price per GB-month.
	SnapshotStoragePerGBMonth = 0.08
)

// MiBPerGB converts mebibytes to gibibytes for the GB-based constants. AWS bills
// memory in GB; we treat the configured MiB baseline as MiB/1024 GB.
const MiBPerGB = 1024.0

// Baseline memory (MiB) per image variant. Mirrors microvm image
// sizing. The provisioner does not read these from the image at runtime, so we
// keep a local table keyed by variant to estimate vCPU/memory cost.
var baselineMiB = map[string]float64{
	"base": 512,
	"mpl":  1024,
	"sci":  1024,
}

// BaselineMiB returns the configured baseline memory for a variant, defaulting
// to 1024 MiB for unknown variants.
func BaselineMiB(variant string) float64 {
	if m, ok := baselineMiB[variant]; ok {
		return m
	}
	return 1024
}

// vcpuForBaseline derives baseline vCPU from baseline memory: AWS allocates
// 1 vCPU per 2 GB of baseline memory (API-FACTS).
func vcpuForBaseline(miB float64) float64 {
	gb := miB / MiBPerGB
	return gb / 2.0
}

// Estimate captures the inputs needed to compute a per-run cost estimate.
type Estimate struct {
	Variant string
	// ComputeMs is the wall time the microVM was actively billed (we use the
	// observed total provisioner+exec window as a proxy for active compute).
	ComputeMs float64
	// Suspended is true when the lifecycle preset will suspend the microVM,
	// incurring a snapshot WRITE cost.
	Suspended bool
	// Resumed is true when this run resumed from a snapshot (snapshot READ).
	Resumed bool
	// ColdCreate is true when this run launched from the image snapshot
	// (snapshot READ of the clean image).
	ColdCreate bool
}

// Compute returns a USD estimate for a single run. Compute cost uses the active
// window (ComputeMs); snapshot read/write costs use the baseline memory size as
// the snapshot-size proxy (the real dirtied-page size is unknown to the
// provisioner — this remains an open measurement).
func Compute(e Estimate) float64 {
	miB := BaselineMiB(e.Variant)
	gb := miB / MiBPerGB
	vcpu := vcpuForBaseline(miB)
	secs := e.ComputeMs / 1000.0

	cost := vcpu*VCPUPerSec*secs + gb*MemPerGBSec*secs

	// Snapshot READ on cold-create (clean image) or resume (suspend snapshot).
	if e.ColdCreate || e.Resumed {
		cost += gb * SnapshotReadPerGB
	}
	// Snapshot WRITE when the preset will suspend.
	if e.Suspended {
		cost += gb * SnapshotWritePerGB
	}
	return cost
}
