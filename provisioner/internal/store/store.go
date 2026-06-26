// Package store writes one result row per run to DynamoDB (CONTRACTS §F). All
// writes are best-effort: an error never fails the browser request (CONTRACTS §F).
package store

import (
	"context"
	"fmt"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	awsconfig "github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/feature/dynamodb/attributevalue"
	"github.com/aws/aws-sdk-go-v2/service/dynamodb"
)

// DDBAPI is the DynamoDB subset used here.
type DDBAPI interface {
	PutItem(ctx context.Context, in *dynamodb.PutItemInput, opts ...func(*dynamodb.Options)) (*dynamodb.PutItemOutput, error)
}

// Store writes result rows to a DynamoDB table.
type Store struct {
	api   DDBAPI
	table string
}

// New builds a Store. The DynamoDB table is global (us-east-1 home per
// CONTRACTS §D); we pin the client to us-east-1 regardless of the provisioner
// region so all regions write to the one table.
func New(ctx context.Context, table string) (*Store, error) {
	cfg, err := awsconfig.LoadDefaultConfig(ctx, awsconfig.WithRegion("us-east-1"))
	if err != nil {
		return nil, fmt.Errorf("load aws config: %w", err)
	}
	return &Store{api: dynamodb.NewFromConfig(cfg), table: table}, nil
}

// NewWithAPI builds a Store around an injected client (tests).
func NewWithAPI(api DDBAPI, table string) *Store {
	return &Store{api: api, table: table}
}

// Item is the result row (CONTRACTS §F). Timings are flattened into a map and
// stored under "timings".
type Item struct {
	RunID            string             `dynamodbav:"runId"`
	VariantRegion    string             `dynamodbav:"variantRegion"` // GSI byVariantRegion PK
	TS               int64              `dynamodbav:"ts"`            // epoch ms (also GSI SK)
	Region           string             `dynamodbav:"region"`
	Variant          string             `dynamodbav:"variant"`
	Regime           string             `dynamodbav:"regime"`
	Lifecycle        string             `dynamodbav:"lifecycle"`
	MicrovmID        string             `dynamodbav:"microvmId"`
	FirstAttemptHeld bool               `dynamodbav:"firstAttemptHeld"`
	ExecRetries      int                `dynamodbav:"execRetries"`
	Timings          map[string]float64 `dynamodbav:"timings"`
	CostEstimateUsd  float64            `dynamodbav:"costEstimateUsd"`
}

// Put writes the item best-effort. Returns an error for the caller to log; the
// caller must NOT fail the request on it (CONTRACTS §F).
func (s *Store) Put(ctx context.Context, it Item) error {
	if s == nil || s.api == nil || s.table == "" {
		return fmt.Errorf("store not configured")
	}
	if it.TS == 0 {
		it.TS = time.Now().UnixMilli()
	}
	if it.VariantRegion == "" {
		it.VariantRegion = it.Variant + "#" + it.Region
	}
	av, err := attributevalue.MarshalMap(it)
	if err != nil {
		return fmt.Errorf("marshal item: %w", err)
	}
	_, err = s.api.PutItem(ctx, &dynamodb.PutItemInput{
		TableName: aws.String(s.table),
		Item:      av,
	})
	if err != nil {
		return fmt.Errorf("put item: %w", err)
	}
	return nil
}
