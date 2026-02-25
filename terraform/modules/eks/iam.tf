# -----------------------------------------------------------------------------
# EKS Module - IAM Roles and Policies
# -----------------------------------------------------------------------------
# Defines all IAM roles needed for EKS operation:
# 1. Cluster role: allows EKS service to manage AWS resources
# 2. Node group role: allows EC2 instances to join the cluster
# 3. External Secrets Operator IRSA role: allows ESO to read Secrets Manager
# -----------------------------------------------------------------------------

# -----------------------------------------------------------------------------
# EKS Cluster IAM Role
# -----------------------------------------------------------------------------
# This role is assumed by the EKS service to create and manage the
# Kubernetes control plane, including ENIs, security groups, and logging.
resource "aws_iam_role" "eks_cluster" {
  name = "${local.cluster_name}-cluster-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "EKSClusterAssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "eks.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = merge(local.common_tags, {
    Name = "${local.cluster_name}-cluster-role"
  })
}

# AmazonEKSClusterPolicy: required for EKS cluster operation
resource "aws_iam_role_policy_attachment" "eks_cluster_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
  role       = aws_iam_role.eks_cluster.name
}

# AmazonEKSVPCResourceController: required for security group management
# on ENIs created for pod networking
resource "aws_iam_role_policy_attachment" "eks_vpc_resource_controller" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSVPCResourceController"
  role       = aws_iam_role.eks_cluster.name
}

# -----------------------------------------------------------------------------
# EKS Node Group IAM Role
# -----------------------------------------------------------------------------
# This role is assumed by EC2 instances in the managed node group.
# It grants permissions for: joining the cluster, pulling container images,
# and managing VPC networking for pods.
resource "aws_iam_role" "eks_node_group" {
  name = "${local.cluster_name}-node-group-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "EC2AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = merge(local.common_tags, {
    Name = "${local.cluster_name}-node-group-role"
  })
}

# AmazonEKSWorkerNodePolicy: allows nodes to connect to the EKS cluster
resource "aws_iam_role_policy_attachment" "eks_worker_node_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
  role       = aws_iam_role.eks_node_group.name
}

# AmazonEKS_CNI_Policy: allows the VPC CNI plugin to manage network interfaces
# for pod IP address allocation
resource "aws_iam_role_policy_attachment" "eks_cni_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
  role       = aws_iam_role.eks_node_group.name
}

# AmazonEC2ContainerRegistryReadOnly: allows nodes to pull container images
# from Amazon ECR (including EKS addon images)
resource "aws_iam_role_policy_attachment" "eks_container_registry_readonly" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
  role       = aws_iam_role.eks_node_group.name
}

# -----------------------------------------------------------------------------
# IRSA Role - External Secrets Operator
# -----------------------------------------------------------------------------
# This role uses IRSA (IAM Roles for Service Accounts) to grant the
# External Secrets Operator pod-level access to AWS Secrets Manager.
# Only the ESO service account in the transaction-engine namespace
# can assume this role, following the principle of least privilege.

resource "aws_iam_role" "external_secrets" {
  name = "${local.cluster_name}-external-secrets-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ExternalSecretsIRSA"
        Effect = "Allow"
        Principal = {
          Federated = aws_iam_openid_connect_provider.eks.arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "${replace(aws_eks_cluster.main.identity[0].oidc[0].issuer, "https://", "")}:sub" = "system:serviceaccount:transaction-engine:external-secrets-sa"
            "${replace(aws_eks_cluster.main.identity[0].oidc[0].issuer, "https://", "")}:aud" = "sts.amazonaws.com"
          }
        }
      }
    ]
  })

  tags = merge(local.common_tags, {
    Name = "${local.cluster_name}-external-secrets-role"
  })
}

# Custom policy granting read-only access to Secrets Manager secrets
# scoped to the transaction-engine path prefix
resource "aws_iam_policy" "external_secrets" {
  name        = "${local.cluster_name}-external-secrets-policy"
  description = "Allows External Secrets Operator to read secrets from AWS Secrets Manager for the transaction-engine namespace"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "SecretsManagerReadAccess"
        Effect = "Allow"
        Action = [
          "secretsmanager:GetResourcePolicy",
          "secretsmanager:GetSecretValue",
          "secretsmanager:DescribeSecret",
          "secretsmanager:ListSecretVersionIds",
        ]
        # Scope access to secrets with the transaction-engine prefix only
        Resource = "arn:aws:secretsmanager:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:secret:transaction-engine/*"
      },
      {
        Sid    = "SecretsManagerListAccess"
        Effect = "Allow"
        Action = [
          "secretsmanager:ListSecrets",
        ]
        Resource = "*"
      },
    ]
  })

  tags = merge(local.common_tags, {
    Name = "${local.cluster_name}-external-secrets-policy"
  })
}

resource "aws_iam_role_policy_attachment" "external_secrets" {
  policy_arn = aws_iam_policy.external_secrets.arn
  role       = aws_iam_role.external_secrets.name
}
