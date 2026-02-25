# -----------------------------------------------------------------------------
# EKS Module - Outputs
# -----------------------------------------------------------------------------

output "cluster_id" {
  description = "The ID of the EKS cluster."
  value       = aws_eks_cluster.main.id
}

output "cluster_name" {
  description = "The name of the EKS cluster."
  value       = aws_eks_cluster.main.name
}

output "cluster_endpoint" {
  description = "The endpoint URL for the EKS cluster API server."
  value       = aws_eks_cluster.main.endpoint
}

output "cluster_security_group_id" {
  description = "The ID of the security group created for the EKS cluster."
  value       = aws_security_group.eks_cluster.id
}

output "cluster_default_security_group_id" {
  description = "The ID of the default security group created by EKS."
  value       = aws_eks_cluster.main.vpc_config[0].cluster_security_group_id
}

output "oidc_provider_arn" {
  description = "The ARN of the OIDC provider for IRSA (IAM Roles for Service Accounts)."
  value       = aws_iam_openid_connect_provider.eks.arn
}

output "oidc_provider_url" {
  description = "The URL of the OIDC provider (without https:// prefix)."
  value       = replace(aws_eks_cluster.main.identity[0].oidc[0].issuer, "https://", "")
}

output "cluster_certificate_authority" {
  description = "The base64-encoded certificate authority data for the cluster."
  value       = aws_eks_cluster.main.certificate_authority[0].data
  sensitive   = true
}

output "cluster_version" {
  description = "The Kubernetes version of the EKS cluster."
  value       = aws_eks_cluster.main.version
}

output "node_group_arn" {
  description = "The ARN of the EKS managed node group."
  value       = aws_eks_node_group.workers.arn
}

output "node_group_role_arn" {
  description = "The ARN of the IAM role used by the node group."
  value       = aws_iam_role.eks_node_group.arn
}

output "external_secrets_role_arn" {
  description = "The ARN of the IRSA role for External Secrets Operator."
  value       = aws_iam_role.external_secrets.arn
}

output "kms_key_arn" {
  description = "The ARN of the KMS key used for EKS secrets encryption."
  value       = aws_kms_key.eks_secrets.arn
}
