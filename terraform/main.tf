terraform {
  required_version = ">= 1.6.0"

  backend "s3" {
    bucket         = "dt-demo-tfstate"
    key            = "observability-demo/terraform.tfstate"
    region         = "ap-southeast-2"
    encrypt        = true
    use_lockfile   = true
    profile        = "dt"
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.0"
    }
    # Note: hashicorp/template provider is intentionally NOT listed here.
    # cloud-init templating uses the built-in templatefile() function instead.
  }
}

provider "aws" {
  region  = var.aws_region
  profile = var.aws_profile

  default_tags {
    tags = {
      Project     = "dt-observability-demo"
      Environment = "demo"
      ManagedBy   = "terraform"
      Owner       = "observability-team"
    }
  }
}
