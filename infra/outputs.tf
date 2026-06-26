################################################################################
# outputs.tf — surface key values for scripts and operators
################################################################################

output "provisioner_url_us_east_1" {
  description = "Provisioner Lambda Function URL — us-east-1"
  value       = module.region_use1.provisioner_function_url
}

output "provisioner_url_us_west_2" {
  description = "Provisioner Lambda Function URL — us-west-2"
  value       = module.region_usw2.provisioner_function_url
}

output "results_table_name" {
  description = "DynamoDB results table name"
  value       = module.global.results_table_name
}

output "results_table_arn" {
  description = "DynamoDB results table ARN"
  value       = module.global.results_table_arn
}

output "build_role_arn" {
  description = "IAM role ARN for image builds"
  value       = module.global.build_role_arn
}

output "exec_role_arn" {
  description = "IAM role ARN attached to running microVMs"
  value       = module.global.exec_role_arn
}

output "provisioner_role_arn" {
  description = "IAM role ARN for provisioner Lambda"
  value       = module.global.provisioner_role_arn
}

output "reaper_role_arn" {
  description = "IAM role ARN for reaper Lambda"
  value       = module.global.reaper_role_arn
}

output "artifacts_bucket_us_east_1" {
  description = "S3 artifact bucket — us-east-1"
  value       = module.region_use1.artifacts_bucket
}

output "artifacts_bucket_us_west_2" {
  description = "S3 artifact bucket — us-west-2"
  value       = module.region_usw2.artifacts_bucket
}

output "dashboard_us_east_1" {
  description = "CloudWatch dashboard name — us-east-1"
  value       = module.region_use1.dashboard_name
}

output "dashboard_us_west_2" {
  description = "CloudWatch dashboard name — us-west-2"
  value       = module.region_usw2.dashboard_name
}

# ---------------------------------------------------------------------------
# Frontend (AWS-native: CloudFront + S3)
# ---------------------------------------------------------------------------
output "app_url" {
  description = "Open in a browser to test BOTH regions (region selector in the UI). The ?k= token unlocks /api/*."
  value       = module.frontend.app_url
}

output "cloudfront_url" {
  description = "CloudFront distribution URL (SPA + /api/use1/* + /api/usw2/*)"
  value       = module.frontend.cloudfront_url
}

output "cloudfront_distribution_id" {
  description = "CloudFront distribution ID (for cache invalidation)"
  value       = module.frontend.distribution_id
}

output "spa_bucket" {
  description = "S3 bucket the SPA is synced to"
  value       = module.frontend.spa_bucket
}

output "frontend_gate_token" {
  description = "Access-gate token for /api/* (sent as ?k= / X-Gate)"
  value       = module.frontend.gate_token
}
