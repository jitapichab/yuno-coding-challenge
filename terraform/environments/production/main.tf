# -----------------------------------------------------------------------------
# Production Environment - Transaction Engine EKS Deployment
# -----------------------------------------------------------------------------
# This is the production deployment configuration for Yuno's TransactionEngine.
# It provisions a VPC with 3 AZs and an EKS cluster with managed node groups.
#
# Usage:
#   cp terraform.tfvars.example terraform.tfvars
#   terraform init
#   terraform plan
#   terraform apply
#
# Prerequisites:
#   - AWS CLI configured with appropriate credentials
#   - Terraform >= 1.5.0
#   - S3 bucket and DynamoDB table for remote state (if using backend)
# -----------------------------------------------------------------------------

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }

  # Backend configuration for remote state
  # Uncomment and configure for production use:
  # backend "s3" {
  #   bucket         = "yuno-terraform-state"
  #   key            = "production/transaction-engine/terraform.tfstate"
  #   region         = "us-east-1"
  #   encrypt        = true
  #   dynamodb_table = "terraform-locks"
  # }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = "transaction-engine"
      Environment = "production"
      ManagedBy   = "terraform"
      Team        = "payment-infrastructure"
    }
  }
}

# -----------------------------------------------------------------------------
# Networking Module
# -----------------------------------------------------------------------------
# Creates VPC, subnets, NAT gateway, and route tables.
module "networking" {
  source       = "../../modules/networking"
  vpc_cidr     = var.vpc_cidr
  environment  = "production"
  project_name = "transaction-engine"
}

# -----------------------------------------------------------------------------
# EKS Module
# -----------------------------------------------------------------------------
# Creates the EKS cluster, managed node groups, and IAM roles.
# Production configuration: 3 worker nodes (t3.medium), scalable up to 10.
module "eks" {
  source              = "../../modules/eks"
  cluster_name        = "yuno-production"
  cluster_version     = "1.29"
  vpc_id              = module.networking.vpc_id
  private_subnet_ids  = module.networking.private_subnet_ids
  node_instance_types = ["t3.medium"]
  node_min_size       = 3
  node_max_size       = 10
  node_desired_size   = 3
  environment         = "production"
}
