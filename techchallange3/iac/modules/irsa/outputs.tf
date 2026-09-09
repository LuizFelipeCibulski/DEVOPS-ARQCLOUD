output "role_arn" {
  description = "ARN para anotar na ServiceAccount (eks.amazonaws.com/role-arn)"
  value       = aws_iam_role.this.arn
}

output "role_name" {
  value = aws_iam_role.this.name
}

output "annotation" {
  description = "Anotacao pronta para colar no metadata.annotations da ServiceAccount"
  value       = "eks.amazonaws.com/role-arn: ${aws_iam_role.this.arn}"
}
