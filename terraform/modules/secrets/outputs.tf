output "secret_arns" {
  value = { for k, s in aws_secretsmanager_secret.svc : k => s.arn }
}

output "irsa_role_arns" {
  value = { for k, r in aws_iam_role.svc : k => r.arn }
}

output "kms_key_arn" {
  value = aws_kms_key.secrets.arn
}
