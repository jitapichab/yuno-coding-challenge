# -----------------------------------------------------------------------------
# Staging Environment - Transaction Engine EKS Deployment
# -----------------------------------------------------------------------------
# Staging mirrors production architecture at reduced scale for cost savings.
# Differences from production:
#   - Smaller node group: 2 nodes (t3.small) instead of 3 (t3.medium)
#   - Lower max scaling: 4 nodes instead of 10
#   - Single NAT Gateway (same as production; see networking module comments)
#
# Usage:
#   cp terraform.tfvars.example terraform.tfvars
#   terraform init
#   terraform plan
#   terraform apply
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
  # Uncomment and configure for staging use:
  # backend "s3" {
  #   bucket         = "yuno-terraform-state"
  #   key            = "staging/transaction-engine/terraform.tfstate"
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
      Environment = "staging"
      ManagedBy   = "terraform"
      Team        = "payment-infrastructure"
    }
  }
}

# -----------------------------------------------------------------------------
# Networking Module
# -----------------------------------------------------------------------------
# Creates VPC, subnets, NAT gateway, and route tables.
# Same network topology as production for realistic testing.
module "networking" {
  source       = "../../modules/networking"
  vpc_cidr     = var.vpc_cidr
  environment  = "staging"
  project_name = "transaction-engine"
}

# -----------------------------------------------------------------------------
# EKS Module
# -----------------------------------------------------------------------------
# Creates the EKS cluster, managed node groups, and IAM roles.
# Staging configuration: 2 worker nodes (t3.small), scalable up to 4.
# Uses smaller instances to reduce costs while maintaining architectural parity.
module "eks" {
  source              = "../../modules/eks"
  cluster_name        = "yuno-staging"
  cluster_version     = "1.29"
  vpc_id              = module.networking.vpc_id
  private_subnet_ids  = module.networking.private_subnet_ids
  node_instance_types = ["t3.small"]
  node_min_size       = 2
  node_max_size       = 4
  node_desired_size   = 2
  environment         = "staging"
}
