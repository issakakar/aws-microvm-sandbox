################################################################################
# modules/frontend/main.tf — AWS-native browser frontend (CloudFront + S3).
#
# One global CloudFront distribution that fronts:
#   - an S3 origin (private, OAC) serving the static SPA   -> default behavior
#   - the us-east-1 provisioner Lambda Function URL (OAC)  -> /api/use1/*
#   - the us-west-2 provisioner Lambda Function URL (OAC)  -> /api/usw2/*
#
# WHY: the provisioner Function URLs are auth=AWS_IAM (the Org SCP blocks public
# auth=NONE). A browser can't SigV4-sign. CloudFront Origin Access Control (OAC)
# signs each /api/* request with SigV4 on the browser's behalf (origin type
# "lambda"), so there is NO cross-cloud hop and NO browser-held credential — the
# whole path is AWS. Region is selected by PATH (the SPA posts to /api/use1/run
# or /api/usw2/run); the provisioner ignores the path and reads only the body.
################################################################################

terraform {
  required_providers {
    aws = {
      source                = "hashicorp/aws"
      version               = "~> 5.0"
      configuration_aliases = [aws, aws.usw2]
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

variable "account_id" {
  type        = string
  description = "AWS account ID"
}

variable "provisioner_fn_name_use1" {
  type        = string
  description = "us-east-1 provisioner Lambda function name (for the CloudFront invoke permission)"
}

variable "provisioner_fn_name_usw2" {
  type        = string
  description = "us-west-2 provisioner Lambda function name"
}

variable "provisioner_url_use1" {
  type        = string
  description = "us-east-1 provisioner Function URL (https://...)"
}

variable "provisioner_url_usw2" {
  type        = string
  description = "us-west-2 provisioner Function URL (https://...)"
}

locals {
  tags = { Project = "microvm-bench" }

  # CloudFront origins need the bare host (no scheme, no trailing slash).
  api_host_use1 = replace(replace(var.provisioner_url_use1, "https://", ""), "/", "")
  api_host_usw2 = replace(replace(var.provisioner_url_usw2, "https://", ""), "/", "")
}

# ---------------------------------------------------------------------------
# Access gate token — a light guess-guard so a found CloudFront URL can't burn
# AWS spend on /api/*. NOT a real secret (the true guards are OAC-only invoke +
# the reaper). The SPA reads it from ?k=<token>, persists it, and sends X-Gate.
# ---------------------------------------------------------------------------
resource "random_string" "gate" {
  length  = 24
  special = false
}

# ---------------------------------------------------------------------------
# S3 bucket — the static SPA (private; reachable only via CloudFront OAC).
# ---------------------------------------------------------------------------
resource "aws_s3_bucket" "spa" {
  bucket = "microvm-bench-spa-${var.account_id}"
  tags   = local.tags
}

resource "aws_s3_bucket_public_access_block" "spa" {
  bucket                  = aws_s3_bucket.spa.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "spa" {
  bucket = aws_s3_bucket.spa.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# ---------------------------------------------------------------------------
# Origin Access Control — one for the S3 origin, one shared by both Lambda
# origins. signing=always/sigv4 makes CloudFront sign every forwarded request.
# ---------------------------------------------------------------------------
resource "aws_cloudfront_origin_access_control" "s3" {
  name                              = "microvm-bench-spa-oac"
  description                       = "OAC for the microvm-bench SPA S3 origin"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_cloudfront_origin_access_control" "lambda" {
  name                              = "microvm-bench-api-oac"
  description                       = "OAC for the microvm-bench provisioner Lambda URL origins"
  origin_access_control_origin_type = "lambda"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

# ---------------------------------------------------------------------------
# Managed cache / origin-request policies.
#   - CachingOptimized for the static SPA.
#   - CachingDisabled for /api/* (POST is never cached; forward query strings).
#   - AllViewerExceptHostHeader forwards every viewer header EXCEPT Host (so
#     CloudFront sets Host to the origin for a correct SigV4 signature) — the
#     policy AWS documents for OAC-signed Lambda URL origins.
# ---------------------------------------------------------------------------
data "aws_cloudfront_cache_policy" "optimized" {
  name = "Managed-CachingOptimized"
}

data "aws_cloudfront_cache_policy" "disabled" {
  name = "Managed-CachingDisabled"
}

data "aws_cloudfront_origin_request_policy" "all_viewer_except_host" {
  name = "Managed-AllViewerExceptHostHeader"
}

# ---------------------------------------------------------------------------
# CloudFront Function (viewer-request) — the access gate. Returns 401 unless the
# request carries the right token (X-Gate header or ?k=). Empty token = no gate.
# ---------------------------------------------------------------------------
resource "aws_cloudfront_function" "gate" {
  name    = "microvm-bench-api-gate"
  runtime = "cloudfront-js-2.0"
  comment = "Access gate for /api/* (X-Gate header or ?k= query)"
  publish = true
  code    = <<-EOT
    function handler(event) {
      var request = event.request;
      var GATE = "${random_string.gate.result}";
      if (GATE !== "") {
        var headers = request.headers;
        var qs = request.querystring;
        var provided = "";
        if (headers["x-gate"] && headers["x-gate"].value) { provided = headers["x-gate"].value; }
        else if (qs["k"] && qs["k"].value) { provided = qs["k"].value; }
        if (provided !== GATE) {
          return {
            statusCode: 401,
            statusDescription: "Unauthorized",
            headers: { "content-type": { value: "application/json" } },
            body: "{\"ok\":false,\"error\":\"unauthorized: open the app via the ?k=<token> link once\"}"
          };
        }
      }
      return request;
    }
  EOT
}

# ---------------------------------------------------------------------------
# CloudFront distribution
# ---------------------------------------------------------------------------
resource "aws_cloudfront_distribution" "this" {
  enabled             = true
  is_ipv6_enabled     = true
  comment             = "microvm-bench SPA + regional provisioner API (OAC SigV4)"
  default_root_object = "index.html"
  price_class         = "PriceClass_100"

  origin {
    origin_id                = "spa"
    domain_name              = aws_s3_bucket.spa.bucket_regional_domain_name
    origin_access_control_id = aws_cloudfront_origin_access_control.s3.id
  }

  origin {
    origin_id                = "api-use1"
    domain_name              = local.api_host_use1
    origin_access_control_id = aws_cloudfront_origin_access_control.lambda.id
    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "https-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }

  origin {
    origin_id                = "api-usw2"
    domain_name              = local.api_host_usw2
    origin_access_control_id = aws_cloudfront_origin_access_control.lambda.id
    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "https-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }

  # SPA (static assets) — cached.
  default_cache_behavior {
    target_origin_id       = "spa"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD", "OPTIONS"]
    cached_methods         = ["GET", "HEAD"]
    cache_policy_id        = data.aws_cloudfront_cache_policy.optimized.id
    compress               = true
  }

  # us-east-1 API — uncached, OAC-signed, gated.
  ordered_cache_behavior {
    path_pattern             = "/api/use1/*"
    target_origin_id         = "api-use1"
    viewer_protocol_policy   = "https-only"
    allowed_methods          = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods           = ["GET", "HEAD"]
    cache_policy_id          = data.aws_cloudfront_cache_policy.disabled.id
    origin_request_policy_id = data.aws_cloudfront_origin_request_policy.all_viewer_except_host.id
    compress                 = false
    function_association {
      event_type   = "viewer-request"
      function_arn = aws_cloudfront_function.gate.arn
    }
  }

  # us-west-2 API — uncached, OAC-signed, gated.
  ordered_cache_behavior {
    path_pattern             = "/api/usw2/*"
    target_origin_id         = "api-usw2"
    viewer_protocol_policy   = "https-only"
    allowed_methods          = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods           = ["GET", "HEAD"]
    cache_policy_id          = data.aws_cloudfront_cache_policy.disabled.id
    origin_request_policy_id = data.aws_cloudfront_origin_request_policy.all_viewer_except_host.id
    compress                 = false
    function_association {
      event_type   = "viewer-request"
      function_arn = aws_cloudfront_function.gate.arn
    }
  }

  # NOTE: no custom_error_response. The SPA is a single page (no client-side deep
  # routing), so we do NOT remap 403/404 to index.html — doing so would mask real
  # /api/* errors (a Lambda-origin 403 would silently render as the SPA). The root
  # is served via default_root_object; assets resolve directly.

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }

  tags = local.tags
}

# ---------------------------------------------------------------------------
# S3 bucket policy — allow ONLY this CloudFront distribution (OAC) to GetObject.
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "spa" {
  statement {
    sid       = "AllowCloudFrontOAC"
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.spa.arn}/*"]
    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.this.arn]
    }
  }
}

resource "aws_s3_bucket_policy" "spa" {
  bucket = aws_s3_bucket.spa.id
  policy = data.aws_iam_policy_document.spa.json
}

# ---------------------------------------------------------------------------
# Lambda permissions — allow CloudFront (this distribution only) to invoke each
# regional provisioner Function URL. The Function URLs stay AWS_IAM; CloudFront
# signs as the cloudfront.amazonaws.com service principal via OAC.
# ---------------------------------------------------------------------------
# OAC → Lambda URL requires BOTH lambda:InvokeFunctionUrl AND lambda:InvokeFunction
# granted to the CloudFront service principal (per AWS's OAC-for-Lambda docs).
# Missing the second one yields AccessDeniedException even with a valid signature.
resource "aws_lambda_permission" "cf_invoke_url_use1" {
  statement_id           = "AllowCloudFrontInvokeUrl"
  action                 = "lambda:InvokeFunctionUrl"
  function_name          = var.provisioner_fn_name_use1
  principal              = "cloudfront.amazonaws.com"
  source_arn             = aws_cloudfront_distribution.this.arn
  function_url_auth_type = "AWS_IAM"
}

resource "aws_lambda_permission" "cf_invoke_fn_use1" {
  statement_id  = "AllowCloudFrontInvokeFunction"
  action        = "lambda:InvokeFunction"
  function_name = var.provisioner_fn_name_use1
  principal     = "cloudfront.amazonaws.com"
  source_arn    = aws_cloudfront_distribution.this.arn
}

resource "aws_lambda_permission" "cf_invoke_url_usw2" {
  provider               = aws.usw2
  statement_id           = "AllowCloudFrontInvokeUrl"
  action                 = "lambda:InvokeFunctionUrl"
  function_name          = var.provisioner_fn_name_usw2
  principal              = "cloudfront.amazonaws.com"
  source_arn             = aws_cloudfront_distribution.this.arn
  function_url_auth_type = "AWS_IAM"
}

resource "aws_lambda_permission" "cf_invoke_fn_usw2" {
  provider      = aws.usw2
  statement_id  = "AllowCloudFrontInvokeFunction"
  action        = "lambda:InvokeFunction"
  function_name = var.provisioner_fn_name_usw2
  principal     = "cloudfront.amazonaws.com"
  source_arn    = aws_cloudfront_distribution.this.arn
}

# ---------------------------------------------------------------------------
# Outputs
# ---------------------------------------------------------------------------
output "cloudfront_domain" {
  value = aws_cloudfront_distribution.this.domain_name
}

output "cloudfront_url" {
  value = "https://${aws_cloudfront_distribution.this.domain_name}"
}

output "distribution_id" {
  value = aws_cloudfront_distribution.this.id
}

output "spa_bucket" {
  value = aws_s3_bucket.spa.bucket
}

output "gate_token" {
  value = random_string.gate.result
}

output "app_url" {
  description = "Open this in a browser (the ?k= token unlocks /api/*)"
  value       = "https://${aws_cloudfront_distribution.this.domain_name}/?k=${random_string.gate.result}"
}
