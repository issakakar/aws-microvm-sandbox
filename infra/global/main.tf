################################################################################
# global/main.tf — IAM roles + DynamoDB table (account-level, region-agnostic)
################################################################################

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

# ---------------------------------------------------------------------------
# Variables
# ---------------------------------------------------------------------------
variable "account_id" {
  type        = string
  description = "AWS account ID"
}

variable "project_tag" {
  type    = string
  default = "microvm-bench"
}

locals {
  tags = {
    Project = var.project_tag
  }
}

# ---------------------------------------------------------------------------
# Trust policies
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "lambda_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole", "sts:TagSession"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

# ---------------------------------------------------------------------------
# Build role  (used by create-microvm-image to run image build hooks)
# ---------------------------------------------------------------------------
resource "aws_iam_role" "build" {
  name               = "microvm-bench-build-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
  tags               = local.tags
}

data "aws_iam_policy_document" "build_inline" {
  # Image build runs under this role; needs S3 read for the codeArtifact zip
  # (GetObject) plus ListBucket/GetBucketLocation, and CloudWatch Logs.
  statement {
    sid    = "S3ReadArtifacts"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:GetObjectVersion",
    ]
    resources = [
      "arn:aws:s3:::microvm-bench-artifacts-us-east-1-${var.account_id}/*",
      "arn:aws:s3:::microvm-bench-artifacts-us-west-2-${var.account_id}/*",
    ]
  }

  statement {
    sid    = "S3ListArtifacts"
    effect = "Allow"
    actions = [
      "s3:ListBucket",
      "s3:GetBucketLocation",
    ]
    resources = [
      "arn:aws:s3:::microvm-bench-artifacts-us-east-1-${var.account_id}",
      "arn:aws:s3:::microvm-bench-artifacts-us-west-2-${var.account_id}",
    ]
  }

  # The build service writes build logs to /aws/lambda/microvms/<image-name>
  # (NOT /microvm-bench/*). The original scope hid the real build failure and may
  # have caused the build to abort. Match the AWS getting-started build role:
  # logs on all groups (creation requires an unscoped or wildcard target).
  statement {
    sid    = "CloudWatchLogs"
    effect = "Allow"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = ["arn:aws:logs:*:*:*"]
  }
}

resource "aws_iam_role_policy" "build_inline" {
  name   = "microvm-bench-build-inline"
  role   = aws_iam_role.build.name
  policy = data.aws_iam_policy_document.build_inline.json
}

# ---------------------------------------------------------------------------
# Exec role  (attached to microVMs via executionRoleArn; in-VM process uses this)
# ---------------------------------------------------------------------------
resource "aws_iam_role" "exec" {
  name               = "microvm-bench-exec-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
  tags               = local.tags
}

data "aws_iam_policy_document" "exec_inline" {
  statement {
    sid    = "CloudWatchLogs"
    effect = "Allow"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = ["arn:aws:logs:*:${var.account_id}:log-group:/microvm-bench/*:*"]
  }
}

resource "aws_iam_role_policy" "exec_inline" {
  name   = "microvm-bench-exec-inline"
  role   = aws_iam_role.exec.name
  policy = data.aws_iam_policy_document.exec_inline.json
}

# ---------------------------------------------------------------------------
# Provisioner role  (Lambda function role; needs microvm CRUD + DynamoDB + EMF)
# ---------------------------------------------------------------------------
resource "aws_iam_role" "provisioner" {
  name               = "microvm-bench-provisioner-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
  tags               = local.tags
}

data "aws_iam_policy_document" "provisioner_inline" {
  statement {
    sid    = "MicrovmLifecycle"
    effect = "Allow"
    actions = [
      "lambda:RunMicrovm",
      "lambda:GetMicrovm",
      "lambda:SuspendMicrovm",
      "lambda:ResumeMicrovm",
      "lambda:TerminateMicrovm",
      "lambda:CreateMicrovmAuthToken",
    ]
    resources = ["*"]
  }

  # RunMicrovm with ingress/egress connectors requires lambda:PassNetworkConnector
  # on the connector ARNs (verified live — RunMicrovm 403'd without it). The
  # connectors are AWS-managed, per region.
  statement {
    sid       = "PassNetworkConnectors"
    effect    = "Allow"
    actions   = ["lambda:PassNetworkConnector"]
    resources = ["arn:aws:lambda:*:aws:network-connector:aws-network-connector:*"]
  }

  statement {
    sid     = "PassExecRole"
    effect  = "Allow"
    actions = ["iam:PassRole"]
    resources = [
      "arn:aws:iam::${var.account_id}:role/microvm-bench-exec-role",
    ]
    # NOTE: no iam:PassedToService condition. RunMicrovm passes the exec role to
    # the microVM runtime under a service principal that is NOT lambda.amazonaws.com,
    # so a PassedToService=lambda.amazonaws.com condition caused AccessDenied on
    # PassRole (verified live). Scope stays tight via the single role resource ARN.
  }

  statement {
    sid    = "DynamoDB"
    effect = "Allow"
    actions = [
      "dynamodb:PutItem",
      "dynamodb:GetItem",
      "dynamodb:Query",
      "dynamodb:UpdateItem",
    ]
    resources = [
      aws_dynamodb_table.results.arn,
      "${aws_dynamodb_table.results.arn}/index/*",
    ]
  }

  statement {
    sid    = "CloudWatchMetricsEMF"
    effect = "Allow"
    actions = [
      "cloudwatch:PutMetricData",
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "provisioner_inline" {
  name   = "microvm-bench-provisioner-inline"
  role   = aws_iam_role.provisioner.name
  policy = data.aws_iam_policy_document.provisioner_inline.json
}

# ---------------------------------------------------------------------------
# Reaper role  (EventBridge-triggered Lambda; needs TerminateMicrovm + ListMicrovms)
# ---------------------------------------------------------------------------
resource "aws_iam_role" "reaper" {
  name               = "microvm-bench-reaper-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
  tags               = local.tags
}

data "aws_iam_policy_document" "reaper_inline" {
  statement {
    sid    = "MicrovmReap"
    effect = "Allow"
    actions = [
      "lambda:ListMicrovms",
      "lambda:GetMicrovm",
      "lambda:TerminateMicrovm",
      "lambda:ListTags",
    ]
    resources = ["*"]
  }

  statement {
    sid    = "CloudWatchLogs"
    effect = "Allow"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = ["arn:aws:logs:*:${var.account_id}:log-group:/microvm-bench/*:*"]
  }
}

resource "aws_iam_role_policy" "reaper_inline" {
  name   = "microvm-bench-reaper-inline"
  role   = aws_iam_role.reaper.name
  policy = data.aws_iam_policy_document.reaper_inline.json
}

# ---------------------------------------------------------------------------
# DynamoDB — microvm-bench-results  (us-east-1 home; global from infra root)
# ---------------------------------------------------------------------------
resource "aws_dynamodb_table" "results" {
  name         = "microvm-bench-results"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "runId"

  attribute {
    name = "runId"
    type = "S"
  }

  attribute {
    name = "variantRegion"
    type = "S"
  }

  attribute {
    name = "ts"
    type = "N"
  }

  global_secondary_index {
    name            = "byVariantRegion"
    hash_key        = "variantRegion"
    range_key       = "ts"
    projection_type = "ALL"
  }

  tags = local.tags
}

# ---------------------------------------------------------------------------
# Outputs
# ---------------------------------------------------------------------------
output "build_role_arn" {
  value = aws_iam_role.build.arn
}

output "exec_role_arn" {
  value = aws_iam_role.exec.arn
}

output "provisioner_role_arn" {
  value = aws_iam_role.provisioner.arn
}

output "reaper_role_arn" {
  value = aws_iam_role.reaper.arn
}

output "results_table_name" {
  value = aws_dynamodb_table.results.name
}

output "results_table_arn" {
  value = aws_dynamodb_table.results.arn
}
