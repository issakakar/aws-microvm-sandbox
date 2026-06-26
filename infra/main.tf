################################################################################
# main.tf — root: wires global (IAM + DynamoDB) and two per-region modules
################################################################################

# ---------------------------------------------------------------------------
# Global module: IAM roles + DynamoDB table (us-east-1 home)
# ---------------------------------------------------------------------------
module "global" {
  source = "./global"

  account_id = var.account_id

  providers = {
    aws = aws.use1
  }
}

# ---------------------------------------------------------------------------
# Per-region module: us-east-1
# ---------------------------------------------------------------------------
module "region_use1" {
  source = "./modules/region"

  region               = "us-east-1"
  account_id           = var.account_id
  provisioner_role_arn = module.global.provisioner_role_arn
  reaper_role_arn      = module.global.reaper_role_arn
  exec_role_arn        = module.global.exec_role_arn
  results_table_name   = module.global.results_table_name
  image_tag            = var.image_tag
  reaper_ttl_minutes   = var.reaper_ttl_minutes

  providers = {
    aws   = aws.use1
    local = local
  }
}

# ---------------------------------------------------------------------------
# Per-region module: us-west-2
# ---------------------------------------------------------------------------
module "region_usw2" {
  source = "./modules/region"

  region               = "us-west-2"
  account_id           = var.account_id
  provisioner_role_arn = module.global.provisioner_role_arn
  reaper_role_arn      = module.global.reaper_role_arn
  exec_role_arn        = module.global.exec_role_arn
  results_table_name   = module.global.results_table_name
  image_tag            = var.image_tag
  reaper_ttl_minutes   = var.reaper_ttl_minutes

  providers = {
    aws   = aws.usw2
    local = local
  }
}

# ---------------------------------------------------------------------------
# Frontend: one global CloudFront distribution fronting the SPA (S3) + both
# regional provisioner Function URLs (OAC SigV4). The whole browser path is AWS —
# no cross-cloud hop.
# ---------------------------------------------------------------------------
module "frontend" {
  source = "./modules/frontend"

  account_id               = var.account_id
  provisioner_fn_name_use1 = module.region_use1.provisioner_function_name
  provisioner_fn_name_usw2 = module.region_usw2.provisioner_function_name
  provisioner_url_use1     = module.region_use1.provisioner_function_url
  provisioner_url_usw2     = module.region_usw2.provisioner_function_url

  providers = {
    aws      = aws.use1
    aws.usw2 = aws.usw2
    random   = random
  }
}
