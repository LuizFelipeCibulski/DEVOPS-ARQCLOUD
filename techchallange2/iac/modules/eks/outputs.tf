output "cluster_name" {
  value = aws_eks_cluster.this.name
}

output "cluster_endpoint" {
  value = aws_eks_cluster.this.endpoint
}

output "cluster_certificate_authority_data" {
  value = aws_eks_cluster.this.certificate_authority[0].data
}

# SG gerenciado automaticamente pelo EKS e anexado a cada no do cluster -
# usar este ID para liberar acesso ao RDS/ElastiCache a partir dos pods.
output "cluster_security_group_id" {
  value = aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
}

output "node_role_arn" {
  value = local.node_role_arn
}

output "cluster_role_arn" {
  value = local.cluster_role_arn
}

output "oidc_provider_arn" {
  value = length(aws_iam_openid_connect_provider.this) > 0 ? aws_iam_openid_connect_provider.this[0].arn : null
}

output "oidc_issuer_url" {
  value = length(aws_iam_openid_connect_provider.this) > 0 ? aws_eks_cluster.this.identity[0].oidc[0].issuer : null
}
