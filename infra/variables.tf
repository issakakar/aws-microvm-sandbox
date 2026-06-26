################################################################################
# variables.tf — root input variables
################################################################################

variable "account_id" {
  type        = string
  description = "AWS account ID (set via terraform.tfvars or -var account_id=...)"
}

variable "image_tag" {
  type        = string
  description = "Image version / build tag (for labeling; images built out-of-band by build-image.sh)"
  default     = "latest"
}

variable "reaper_ttl_minutes" {
  type        = number
  description = "Reaper kills microVMs older than this many minutes (cost guardrail)"
  default     = 15
}
