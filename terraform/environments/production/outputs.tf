# -----------------------------------------------------------------------------
# Production Environment - Outputs
# -----------------------------------------------------------------------------

output "cluster_endpoint" {
  description = "The endpoint URL for the production EKS cluster API server."
  value       = module.eks.cluster_endpoint
}

output "cluster_name" {
  description = "The name of the production EKS cluster."
  value       = module.eks.cluster_name
}

output "vpc_id" {
  description = "The ID of the production VPC."
  value       = module.networking.vpc_id
}

output "cluster_certificate_authority" {
  description = "The base64-encoded certificate authority data for the cluster."
  value       = module.eks.cluster_certificate_authority
  sensitive   = true
}

output "oidc_provider_arn" {
  description = "The ARN of the OIDC provider for IRSA configuration."
  value       = module.eks.oidc_provider_arn
}

output "external_secrets_role_arn" {
  description = "The ARN of the IRSA role for External Secrets Operator."
  value       = module.eks.external_secrets_role_arn
}

output "configure_kubectl" {
  description = "Command to configure kubectl for this cluster."
  value       = "aws eks update-kubeconfig --region ${var.aws_region} --name ${module.eks.cluster_name}"
}
