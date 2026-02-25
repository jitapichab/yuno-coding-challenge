# -----------------------------------------------------------------------------
# EKS Module - Cluster, Node Groups, Addons, Encryption, Logging
# -----------------------------------------------------------------------------
# Creates a production-grade EKS cluster with:
# - Managed node group for worker workloads
# - OIDC provider for IAM Roles for Service Accounts (IRSA)
# - KMS envelope encryption for Kubernetes secrets
# - Core addons (CoreDNS, kube-proxy, VPC-CNI)
# - CloudWatch logging for audit and API server
# -----------------------------------------------------------------------------

# Fetch current AWS account ID for constructing ARNs
data "aws_caller_identity" "current" {}

# Fetch current region for constructing ARNs
data "aws_region" "current" {}

# Fetch the TLS certificate for the EKS OIDC provider
data "tls_certificate" "eks" {
  url = aws_eks_cluster.main.identity[0].oidc[0].issuer
}

locals {
  cluster_name = "${var.cluster_name}-${var.environment}"

  common_tags = merge(
    {
      Environment = var.environment
      Project     = "transaction-engine"
      ManagedBy   = "terraform"
      Cluster     = local.cluster_name
    },
    var.tags,
  )
}

# -----------------------------------------------------------------------------
# KMS Key - Envelope Encryption for Kubernetes Secrets
# -----------------------------------------------------------------------------
# All Kubernetes secrets are encrypted at rest using this KMS key.
# This is a PCI-DSS requirement for payment processing workloads.
resource "aws_kms_key" "eks_secrets" {
  description             = "KMS key for EKS secrets encryption - ${local.cluster_name}"
  deletion_window_in_days = 30
  enable_key_rotation     = true

  tags = merge(local.common_tags, {
    Name = "${local.cluster_name}-eks-secrets-key"
  })
}

resource "aws_kms_alias" "eks_secrets" {
  name          = "alias/${local.cluster_name}-eks-secrets"
  target_key_id = aws_kms_key.eks_secrets.key_id
}

# -----------------------------------------------------------------------------
# EKS Cluster
# -----------------------------------------------------------------------------
# The control plane is fully managed by AWS. Worker nodes connect via
# private subnets. Both public and private endpoints are enabled:
# - Public: allows kubectl access from CI/CD and developer machines
# - Private: allows node-to-control-plane communication within VPC
resource "aws_eks_cluster" "main" {
  name     = local.cluster_name
  version  = var.cluster_version
  role_arn = aws_iam_role.eks_cluster.arn

  vpc_config {
    subnet_ids              = var.private_subnet_ids
    endpoint_private_access = true
    endpoint_public_access  = true
    security_group_ids      = [aws_security_group.eks_cluster.id]
  }

  # Envelope encryption for Kubernetes secrets using KMS
  encryption_config {
    provider {
      key_arn = aws_kms_key.eks_secrets.arn
    }
    resources = ["secrets"]
  }

  # CloudWatch logging for security audit and troubleshooting
  enabled_cluster_log_types = ["api", "audit", "authenticator"]

  tags = merge(local.common_tags, {
    Name = local.cluster_name
  })

  # Ensure IAM role is created before the cluster
  depends_on = [
    aws_iam_role_policy_attachment.eks_cluster_policy,
    aws_iam_role_policy_attachment.eks_vpc_resource_controller,
  ]

  lifecycle {
    # Prevent accidental deletion of the EKS cluster
    prevent_destroy = true
  }
}

# -----------------------------------------------------------------------------
# EKS Cluster Security Group
# -----------------------------------------------------------------------------
# Additional security group for the EKS cluster control plane.
# The default cluster security group is also created by EKS automatically.
resource "aws_security_group" "eks_cluster" {
  name_prefix = "${local.cluster_name}-cluster-"
  description = "Security group for EKS cluster control plane - ${local.cluster_name}"
  vpc_id      = var.vpc_id

  tags = merge(local.common_tags, {
    Name = "${local.cluster_name}-cluster-sg"
  })

  lifecycle {
    create_before_destroy = true
  }
}

# Allow all outbound traffic from the cluster control plane
resource "aws_security_group_rule" "cluster_egress" {
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.eks_cluster.id
  description       = "Allow all outbound traffic from EKS control plane"
}

# -----------------------------------------------------------------------------
# EKS Managed Node Group
# -----------------------------------------------------------------------------
# Managed node group for running application workloads.
# Uses private subnets to keep worker nodes off the public internet.
# gp3 volumes for better price-performance than gp2.
resource "aws_eks_node_group" "workers" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "${local.cluster_name}-workers"
  node_role_arn   = aws_iam_role.eks_node_group.arn
  subnet_ids      = var.private_subnet_ids

  instance_types = var.node_instance_types
  capacity_type  = "ON_DEMAND"

  scaling_config {
    min_size     = var.node_min_size
    max_size     = var.node_max_size
    desired_size = var.node_desired_size
  }

  # Update configuration: allow rolling updates one node at a time
  update_config {
    max_unavailable = 1
  }

  # Node disk configuration: 50GB gp3 for better IOPS and throughput
  disk_size = 50

  labels = {
    role        = "worker"
    environment = var.environment
  }

  tags = merge(local.common_tags, {
    Name = "${local.cluster_name}-workers"
  })

  # Ensure IAM policies are attached before creating the node group
  depends_on = [
    aws_iam_role_policy_attachment.eks_worker_node_policy,
    aws_iam_role_policy_attachment.eks_cni_policy,
    aws_iam_role_policy_attachment.eks_container_registry_readonly,
  ]

  lifecycle {
    # Ignore changes to desired_size to prevent conflicts with cluster autoscaler
    ignore_changes = [scaling_config[0].desired_size]
  }
}

# -----------------------------------------------------------------------------
# Launch Template for gp3 EBS volumes
# -----------------------------------------------------------------------------
# Note: aws_eks_node_group disk_size uses the default volume type.
# For explicit gp3 configuration, a launch template can be used.
# The disk_size parameter above creates gp3 volumes by default on
# Amazon Linux 2023 AMIs used by EKS 1.29+.

# -----------------------------------------------------------------------------
# OIDC Provider for IRSA (IAM Roles for Service Accounts)
# -----------------------------------------------------------------------------
# Enables Kubernetes service accounts to assume IAM roles.
# Used by: External Secrets Operator, AWS Load Balancer Controller,
# Cluster Autoscaler, and application workloads needing AWS API access.
resource "aws_iam_openid_connect_provider" "eks" {
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.eks.certificates[0].sha1_fingerprint]
  url             = aws_eks_cluster.main.identity[0].oidc[0].issuer

  tags = merge(local.common_tags, {
    Name = "${local.cluster_name}-oidc-provider"
  })
}

# -----------------------------------------------------------------------------
# EKS Addons
# -----------------------------------------------------------------------------
# CoreDNS: cluster-internal DNS resolution for service discovery
resource "aws_eks_addon" "coredns" {
  cluster_name                = aws_eks_cluster.main.name
  addon_name                  = "coredns"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  tags = merge(local.common_tags, {
    Name = "${local.cluster_name}-addon-coredns"
  })

  depends_on = [aws_eks_node_group.workers]
}

# kube-proxy: network proxy for Kubernetes services on each node
resource "aws_eks_addon" "kube_proxy" {
  cluster_name                = aws_eks_cluster.main.name
  addon_name                  = "kube-proxy"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  tags = merge(local.common_tags, {
    Name = "${local.cluster_name}-addon-kube-proxy"
  })
}

# VPC-CNI: Amazon VPC networking for pod IP address management
resource "aws_eks_addon" "vpc_cni" {
  cluster_name                = aws_eks_cluster.main.name
  addon_name                  = "vpc-cni"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  tags = merge(local.common_tags, {
    Name = "${local.cluster_name}-addon-vpc-cni"
  })
}
