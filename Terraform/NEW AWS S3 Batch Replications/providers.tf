variable "aws_region" {
  description = "AWS region (e.g. us-east-2)"
  type        = string
  default     = "us-east-2"
}

provider "aws" {
  region = var.aws_region
}
