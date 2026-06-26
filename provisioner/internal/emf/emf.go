// Package emf emits CloudWatch Embedded Metric Format (EMF) blobs to stdout.
// The Lambda log driver parses these into CloudWatch Metrics with no PutMetricData
// calls. One blob is emitted per run, best-effort.
package emf

import (
	"encoding/json"
	"fmt"
	"os"
	"sort"
	"strings"
	"time"
)

// Namespace is the CloudWatch metric namespace for the bench.
const Namespace = "microvm-bench"

// Metric is one metric value plus its unit.
type Metric struct {
	Name  string
	Value float64
	Unit  string // e.g. "Milliseconds", "Count", "None"
}

// Blob is a single EMF emission: dimensions (string properties used as metric
// dimensions) plus a set of metric values.
type Blob struct {
	// Dimensions are the dimension key/value pairs (region, variant, regime,
	// lifecycle). They are emitted both as the dimension set(s) and as root
	// properties (EMF requires the values present at the root). Keys whose value
	// is empty are dropped (CloudWatch silently discards a metric whose declared
	// dimension has an empty value — e.g. on an early-error path with no variant).
	Dimensions map[string]string
	// DimensionSets lists the dimension combinations to publish each metric
	// against (CloudWatch aggregates per set). Each inner slice is dimension
	// KEYS; keys absent/empty in Dimensions are filtered out and resulting
	// duplicate/empty sets de-duplicated. A nil DimensionSets defaults to one set
	// of all present keys. Emitting e.g. {{"region"},{"region","variant"},
	// {"region","variant","regime","lifecycle"}} lets dashboards aggregate by
	// region alone as well as by the full breakdown.
	DimensionSets [][]string
	Metrics       []Metric
}

// directive is the internal `_aws` envelope EMF requires.
type directive struct {
	Timestamp         int64               `json:"Timestamp"`
	CloudWatchMetrics []cloudWatchMetrics `json:"CloudWatchMetrics"`
}

type cloudWatchMetrics struct {
	Namespace  string             `json:"Namespace"`
	Dimensions [][]string         `json:"Dimensions"`
	Metrics    []metricDefinition `json:"Metrics"`
}

type metricDefinition struct {
	Name string `json:"Name"`
	Unit string `json:"Unit,omitempty"`
}

// Emit marshals the blob to EMF JSON and writes one line to stdout. Errors are
// returned but callers treat emission as best-effort.
func Emit(b Blob) error {
	root := map[string]any{}

	// Emit only NON-EMPTY dimension values at the root.
	present := make(map[string]bool, len(b.Dimensions))
	for k, v := range b.Dimensions {
		if v == "" {
			continue
		}
		root[k] = v
		present[k] = true
	}

	metricDefs := make([]metricDefinition, 0, len(b.Metrics))
	for _, m := range b.Metrics {
		root[m.Name] = m.Value
		metricDefs = append(metricDefs, metricDefinition{Name: m.Name, Unit: m.Unit})
	}

	// Resolve dimension sets: filter each requested set to present keys, dedup.
	var sets [][]string
	if b.DimensionSets == nil {
		all := make([]string, 0, len(present))
		for k := range present {
			all = append(all, k)
		}
		sort.Strings(all)
		sets = [][]string{all}
	} else {
		seen := make(map[string]bool)
		for _, set := range b.DimensionSets {
			filtered := make([]string, 0, len(set))
			for _, k := range set {
				if present[k] {
					filtered = append(filtered, k)
				}
			}
			key := strings.Join(filtered, ",")
			if seen[key] {
				continue
			}
			seen[key] = true
			sets = append(sets, filtered)
		}
		if len(sets) == 0 {
			sets = [][]string{{}} // namespace-level (no dimensions)
		}
	}

	root["_aws"] = directive{
		Timestamp: time.Now().UnixMilli(),
		CloudWatchMetrics: []cloudWatchMetrics{{
			Namespace:  Namespace,
			Dimensions: sets,
			Metrics:    metricDefs,
		}},
	}

	data, err := json.Marshal(root)
	if err != nil {
		return fmt.Errorf("emf marshal: %w", err)
	}
	if _, err := fmt.Fprintln(os.Stdout, string(data)); err != nil {
		return fmt.Errorf("emf write: %w", err)
	}
	return nil
}

// Bool01 converts a bool to a 0/1 metric value.
func Bool01(b bool) float64 {
	if b {
		return 1
	}
	return 0
}
