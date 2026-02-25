# -----------------------------------------------------------------------------
# Staging Environment - Input Variables
# -----------------------------------------------------------------------------

variable "aws_region" {
  description = "AWS region for deploying the staging infrastructure."
  type        = string
  default     = "us-east-1"

  validation {
    condition     = can(regex("^[a-z]{2}-[a-z]+-[0-9]{1}$", var.aws_region))
    error_message = "The aws_region must be a valid AWS region identifier (e.g., us-east-1, eu-west-1)."
  }
}

variable "vpc_cidr" {
  description = "CIDR block for the staging VPC."
  type        = string
  default     = "10.0.0.0/16"

  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0))
    error_message = "The vpc_cidr must be a valid CIDR block (e.g., 10.0.0.0/16)."
  }
}
