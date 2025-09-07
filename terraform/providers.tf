terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.50"
    }
  }

  backend "s3" {
    bucket = "luit-capston-september2025"
    key    = "luit-capston-september2025/terraform/endstate.tf"
    region = "us-east-1"
  }
}
provider "aws" { region = var.aws_region }