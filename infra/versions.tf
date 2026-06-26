################################################################################
# versions.tf — root provider + terraform version constraints
################################################################################

terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.4"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

# us-east-1 (default)
provider "aws" {
  alias  = "use1"
  region = "us-east-1"

  default_tags {
    tags = {
      Project = "microvm-bench"
    }
  }
}

# us-west-2
provider "aws" {
  alias  = "usw2"
  region = "us-west-2"

  default_tags {
    tags = {
      Project = "microvm-bench"
    }
  }
}
