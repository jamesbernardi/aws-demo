terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 4.62.0"
    }
  }

  required_version = "~> 1.2"
}

provider "aws" {
  region              = var.region
  allowed_account_ids = [var.allowed_account_ids]
}
