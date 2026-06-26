################################################################################
# modules/region/main.tf — per-region resources
# Instantiated twice from infra root (us-east-1, us-west-2).
################################################################################

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.4"
    }
  }
}

# ---------------------------------------------------------------------------
# Variables
# ---------------------------------------------------------------------------
variable "region" {
  type        = string
  description = "AWS region for this module instance (us-east-1 or us-west-2)"
}

variable "account_id" {
  type        = string
  description = "AWS account ID"
}

variable "provisioner_role_arn" {
  type        = string
  description = "ARN of the provisioner Lambda execution role"
}

variable "reaper_role_arn" {
  type        = string
  description = "ARN of the reaper Lambda execution role"
}

variable "results_table_name" {
  type        = string
  description = "DynamoDB results table name (for provisioner env)"
  default     = "microvm-bench-results"
}

variable "exec_role_arn" {
  type        = string
  description = "ARN of the microVM exec role (passed to RunMicrovm)"
}

variable "image_tag" {
  type        = string
  description = "Image version / build tag (for labeling; images built out-of-band)"
  default     = "latest"
}

variable "reaper_ttl_minutes" {
  type        = number
  description = "Reaper kills microVMs older than this many minutes"
  default     = 15
}

locals {
  acct   = var.account_id
  region = var.region

  tags = {
    Project = "microvm-bench"
    Region  = var.region
  }

  # Deterministic image ARNs (§D / §E) — images built out-of-band by build-image.sh
  image_arn_base = "arn:aws:lambda:${var.region}:${var.account_id}:microvm-image:microvm-bench-base"
  image_arn_mpl  = "arn:aws:lambda:${var.region}:${var.account_id}:microvm-image:microvm-bench-mpl"
  image_arn_sci  = "arn:aws:lambda:${var.region}:${var.account_id}:microvm-image:microvm-bench-sci"

  # Connector ARNs (AWS-managed, per region)
  ingress_connector = "arn:aws:lambda:${var.region}:aws:network-connector:aws-network-connector:ALL_INGRESS"
  egress_connector  = "arn:aws:lambda:${var.region}:aws:network-connector:aws-network-connector:INTERNET_EGRESS"

  # Zip paths — built by `make build-provisioner` before apply; placeholder keeps
  # validate green when absent. path.root is the infra/ dir, so the repo's
  # provisioner/dist is ONE level up (infra/../provisioner/dist), not two.
  provisioner_zip_path = "${path.root}/../provisioner/dist/provisioner.zip"
  reaper_zip_path      = "${path.root}/../provisioner/dist/reaper.zip"
}

# ---------------------------------------------------------------------------
# S3 artifact bucket  (microvm-bench-artifacts-<region>-<acct>)
# ---------------------------------------------------------------------------
resource "aws_s3_bucket" "artifacts" {
  bucket = "microvm-bench-artifacts-${var.region}-${var.account_id}"
  tags   = local.tags
}

resource "aws_s3_bucket_versioning" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_public_access_block" "artifacts" {
  bucket                  = aws_s3_bucket.artifacts.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# ---------------------------------------------------------------------------
# CloudWatch Log Groups
# ---------------------------------------------------------------------------
resource "aws_cloudwatch_log_group" "provisioner" {
  name              = "/microvm-bench/provisioner/${var.region}"
  retention_in_days = 14
  tags              = local.tags
}

resource "aws_cloudwatch_log_group" "reaper" {
  name              = "/microvm-bench/reaper/${var.region}"
  retention_in_days = 7
  tags              = local.tags
}

resource "aws_cloudwatch_log_group" "microvm" {
  name              = "/microvm-bench/microvm/${var.region}"
  retention_in_days = 7
  tags              = local.tags
}

# ---------------------------------------------------------------------------
# Zip sources — use a data source with a conditional path so terraform
# validate passes even when the zip hasn't been built yet.
# ---------------------------------------------------------------------------
locals {
  provisioner_zip_exists = fileexists(local.provisioner_zip_path)
  reaper_zip_exists      = fileexists(local.reaper_zip_path)

  # Placeholder zip bytes — an empty but valid zip (PK\x05\x06 end-of-central-dir)
  # written to the scratchpad so validate never errors on a missing file.
  _placeholder_note = "zips built by 'make build' before terraform apply"
}

# Use a local_file data source trick: point filename at the real zip if it
# exists, else fall back to a stable dummy path we create below.
resource "local_file" "provisioner_placeholder" {
  count    = local.provisioner_zip_exists ? 0 : 1
  filename = "/tmp/microvm-bench-provisioner-placeholder.zip"
  # Minimal valid ZIP (empty archive) encoded as base64
  content_base64 = "UEsFBgAAAAAAAAAAAAAAAAAAAAAAAA=="
}

resource "local_file" "reaper_placeholder" {
  count          = local.reaper_zip_exists ? 0 : 1
  filename       = "/tmp/microvm-bench-reaper-placeholder.zip"
  content_base64 = "UEsFBgAAAAAAAAAAAAAAAAAAAAAAAA=="
}

locals {
  provisioner_zip = local.provisioner_zip_exists ? local.provisioner_zip_path : "/tmp/microvm-bench-provisioner-placeholder.zip"
  reaper_zip      = local.reaper_zip_exists ? local.reaper_zip_path : "/tmp/microvm-bench-reaper-placeholder.zip"
}

# ---------------------------------------------------------------------------
# Provisioner Lambda
# ---------------------------------------------------------------------------
resource "aws_lambda_function" "provisioner" {
  function_name    = "microvm-bench-provisioner"
  description      = "microvm-bench provisioner — orchestrates RunMicrovm + /exec, writes results"
  role             = var.provisioner_role_arn
  architectures    = ["arm64"]
  runtime          = "provided.al2023"
  handler          = "bootstrap"
  filename         = local.provisioner_zip
  source_code_hash = filebase64sha256(local.provisioner_zip)
  timeout          = 30
  memory_size      = 256

  environment {
    variables = {
      REGION                = var.region
      RESULTS_TABLE         = var.results_table_name
      EXEC_ROLE_ARN         = var.exec_role_arn
      INGRESS_CONNECTOR_ARN = local.ingress_connector
      EGRESS_CONNECTOR_ARN  = local.egress_connector
      IMAGE_ARN_BASE        = local.image_arn_base
      IMAGE_ARN_MPL         = local.image_arn_mpl
      IMAGE_ARN_SCI         = local.image_arn_sci
      EXEC_PORT             = "8080"
      # Enable in-VM CloudWatch logging on every RunMicrovm so the cold-create
      # timeline is measurable from the VM side (restore-vs-boot, /run→/exec).
      MICROVM_LOG_GROUP = aws_cloudwatch_log_group.microvm.name
    }
  }

  logging_config {
    log_format = "JSON"
    log_group  = aws_cloudwatch_log_group.provisioner.name
  }

  depends_on = [
    local_file.provisioner_placeholder,
  ]

  tags = local.tags
}

# ---------------------------------------------------------------------------
# Provisioner Function URL  (AWS_IAM; CORS open, fronted by CloudFront)
# ---------------------------------------------------------------------------
resource "aws_lambda_function_url" "provisioner" {
  function_name = aws_lambda_function.provisioner.function_name
  # AWS_IAM (not NONE): this account's Org SCP blocks public (auth-NONE) Function
  # URLs (a correct principal:"*" / FunctionUrlAuthType:NONE resource policy still
  # returned 403). Callers SigV4-sign requests (service "lambda"); the harness
  # signs with its profile creds. This also removes the public-abuse/cost risk the
  # NONE design carried. (Browser SPA would need SigV4 or a signing relay.)
  authorization_type = "AWS_IAM"

  cors {
    allow_credentials = false
    allow_headers     = ["content-type", "x-requested-with"]
    # OPTIONS is NOT a valid allowMethods value (Function URLs answer preflight
    # automatically; the API rejects "OPTIONS" — >6 chars / not in the allowed set).
    allow_methods = ["POST"]
    # Function URL CORS does NOT support subdomain wildcards — only exact origins
    # or "*". Requests are AWS_IAM-signed (so CORS is not the security boundary)
    # and the browser reaches this only via CloudFront OAC, so "*" is acceptable
    # here; tighten to the exact CloudFront origin if this is ever left deployed.
    allow_origins  = ["*"]
    expose_headers = ["x-amzn-requestid", "x-amzn-trace-id"]
    max_age        = 86400
  }
}

# ---------------------------------------------------------------------------
# Invoke permission for the (AWS_IAM-auth) Function URL: allow same-account IAM
# principals to invoke. Same-account admin callers are already covered by their
# identity policy; this resource statement makes the grant explicit/auditable.
# ---------------------------------------------------------------------------
resource "aws_lambda_permission" "provisioner_url_invoke" {
  statement_id           = "AllowAccountFunctionUrlInvoke"
  action                 = "lambda:InvokeFunctionUrl"
  function_name          = aws_lambda_function.provisioner.function_name
  principal              = var.account_id
  function_url_auth_type = "AWS_IAM"
}

# ---------------------------------------------------------------------------
# Reaper Lambda
# ---------------------------------------------------------------------------
resource "aws_lambda_function" "reaper" {
  function_name    = "microvm-bench-reaper"
  description      = "microvm-bench reaper — terminates stale microVMs (>TTL minutes old)"
  role             = var.reaper_role_arn
  architectures    = ["arm64"]
  runtime          = "provided.al2023"
  handler          = "bootstrap"
  filename         = local.reaper_zip
  source_code_hash = filebase64sha256(local.reaper_zip)
  timeout          = 300
  memory_size      = 128

  environment {
    variables = {
      REGION = var.region
      # The reaper binary reads REAP_TTL_SECONDS (cmd/reaper/main.go), not
      # REAPER_TTL_MIN — set the name it actually consumes, in seconds, so the
      # configured cost-guardrail TTL is honored instead of silently defaulting.
      REAP_TTL_SECONDS = tostring(var.reaper_ttl_minutes * 60)
      PROJECT_TAG      = "microvm-bench"
    }
  }

  logging_config {
    log_format = "JSON"
    log_group  = aws_cloudwatch_log_group.reaper.name
  }

  depends_on = [
    local_file.reaper_placeholder,
  ]

  tags = local.tags
}

# ---------------------------------------------------------------------------
# EventBridge rule — trigger reaper every 5 minutes
# ---------------------------------------------------------------------------
resource "aws_cloudwatch_event_rule" "reaper" {
  name                = "microvm-bench-reaper-schedule"
  description         = "Trigger microvm-bench reaper every 5 minutes"
  schedule_expression = "rate(5 minutes)"
  tags                = local.tags
}

resource "aws_cloudwatch_event_target" "reaper" {
  rule = aws_cloudwatch_event_rule.reaper.name
  arn  = aws_lambda_function.reaper.arn
}

resource "aws_lambda_permission" "reaper_eventbridge" {
  statement_id  = "AllowEventBridgeInvokeReaper"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.reaper.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.reaper.arn
}

# ---------------------------------------------------------------------------
# CloudWatch Dashboard
# ---------------------------------------------------------------------------
resource "aws_cloudwatch_dashboard" "microvm_bench" {
  dashboard_name = "microvm-bench-${var.region}"

  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "metric"
        x      = 0
        y      = 0
        width  = 12
        height = 6
        properties = {
          title  = "Total Execution Time (ms) — ${var.region}"
          region = var.region
          view   = "timeSeries"
          stat   = "p95"
          period = 60
          metrics = [
            ["microvm-bench", "total_ms", "region", var.region],
          ]
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 0
        width  = 12
        height = 6
        properties = {
          title  = "RunMicrovm Latency (ms) — ${var.region}"
          region = var.region
          view   = "timeSeries"
          stat   = "p95"
          period = 60
          metrics = [
            ["microvm-bench", "run_microvm_ms", "region", var.region],
          ]
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 6
        width  = 8
        height = 6
        properties = {
          title  = "Token Mint & Overlap (ms) — ${var.region}"
          region = var.region
          view   = "timeSeries"
          stat   = "p95"
          period = 60
          metrics = [
            ["microvm-bench", "token_mint_ms", "region", var.region],
            ["microvm-bench", "token_overlap_ms", "region", var.region],
          ]
        }
      },
      {
        type   = "metric"
        x      = 8
        y      = 6
        width  = 8
        height = 6
        properties = {
          title  = "Exec RTT (ms) — ${var.region}"
          region = var.region
          view   = "timeSeries"
          stat   = "p95"
          period = 60
          metrics = [
            ["microvm-bench", "exec_rtt_ms", "region", var.region],
          ]
        }
      },
      {
        type   = "metric"
        x      = 16
        y      = 6
        width  = 8
        height = 6
        properties = {
          title  = "In-VM Timing Breakdown (ms) — ${var.region}"
          region = var.region
          view   = "timeSeries"
          stat   = "p95"
          period = 60
          metrics = [
            ["microvm-bench", "invm_total_ms", "region", var.region],
            ["microvm-bench", "fork_ms", "region", var.region],
            ["microvm-bench", "user_code_ms", "region", var.region],
            ["microvm-bench", "render_ms", "region", var.region],
          ]
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 12
        width  = 8
        height = 6
        properties = {
          title  = "First Attempt Held Rate — ${var.region}"
          region = var.region
          view   = "timeSeries"
          stat   = "Average"
          period = 300
          metrics = [
            ["microvm-bench", "first_attempt_held", "region", var.region],
          ]
        }
      },
      {
        type   = "metric"
        x      = 8
        y      = 12
        width  = 8
        height = 6
        properties = {
          title  = "Exec Retries — ${var.region}"
          region = var.region
          view   = "timeSeries"
          stat   = "Sum"
          period = 300
          metrics = [
            ["microvm-bench", "exec_retries", "region", var.region],
          ]
        }
      },
      {
        type   = "metric"
        x      = 16
        y      = 12
        width  = 8
        height = 6
        properties = {
          title  = "Cost per Run (USD) — ${var.region}"
          region = var.region
          view   = "timeSeries"
          stat   = "Sum"
          period = 3600
          metrics = [
            ["microvm-bench", "cost_usd", "region", var.region],
          ]
        }
      },
    ]
  })
}

# ---------------------------------------------------------------------------
# Outputs
# ---------------------------------------------------------------------------
output "artifacts_bucket" {
  value = aws_s3_bucket.artifacts.bucket
}

output "provisioner_function_url" {
  value = aws_lambda_function_url.provisioner.function_url
}

output "provisioner_function_name" {
  value = aws_lambda_function.provisioner.function_name
}

output "provisioner_function_arn" {
  value = aws_lambda_function.provisioner.arn
}

output "reaper_function_arn" {
  value = aws_lambda_function.reaper.arn
}

output "dashboard_name" {
  value = aws_cloudwatch_dashboard.microvm_bench.dashboard_name
}
