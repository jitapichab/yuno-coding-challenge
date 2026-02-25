# -----------------------------------------------------------------------------
# EKS Module - Input Variables
# -----------------------------------------------------------------------------

variable "cluster_name" {
  description = "Name prefix for the EKS cluster. Will be combined with environment."
  type        = string

  validation {
    condition     = can(regex("^[a-zA-Z][a-zA-Z0-9-]*$", var.cluster_name))
    error_message = "Cluster name must start with a letter and contain only alphanumeric characters and hyphens."
  }
}

variable "cluster_version" {
  description = "Kubernetes version for the EKS cluster."
  type        = string
  default     = "1.29"

  validation {
    condition     = can(regex("^1\\.(2[7-9]|3[0-9])$", var.cluster_version))
    error_message = "Cluster version must be a supported EKS version (1.27+)."
  }
}

variable "vpc_id" {
  description = "ID of the VPC where the EKS cluster will be deployed."
  type        = string
}

variable "private_subnet_ids" {
  description = "List of private subnet IDs for the EKS cluster and worker nodes."
  type        = list(string)

  validation {
    condition     = length(var.private_subnet_ids) >= 2
    error_message = "At least 2 private subnets are required for EKS high availability."
  }
}

variable "node_instance_types" {
  description = "EC2 instance types for the managed node group."
  type        = list(string)
  default     = ["t3.medium"]
}

variable "node_min_size" {
  description = "Minimum number of nodes in the managed node group."
  type        = number
  default     = 3

  validation {
    condition     = var.node_min_size >= 1
    error_message = "Minimum node count must be at least 1."
  }
}

variable "node_max_size" {
  description = "Maximum number of nodes in the managed node group (for autoscaling)."
  type        = number
  default     = 6

  validation {
    condition     = var.node_max_size >= 1
    error_message = "Maximum node count must be at least 1."
  }
}

variable "node_desired_size" {
  description = "Desired number of nodes in the managed node group."
  type        = number
  default     = 3

  validation {
    condition     = var.node_desired_size >= 1
    error_message = "Desired node count must be at least 1."
  }
}

variable "environment" {
  description = "Deployment environment name (e.g., production, staging, development)."
  type        = string

  validation {
    condition     = contains(["production", "staging", "development"], var.environment)
    error_message = "Environment must be one of: production, staging, development."
  }
}

variable "tags" {
  description = "Additional tags to apply to all resources in this module."
  type        = map(string)
  default     = {}
}
