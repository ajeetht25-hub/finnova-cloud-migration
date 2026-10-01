output "cluster_name" {
  value = module.eks.cluster_name
}

output "db_endpoint" {
  value = module.rds.endpoint
}

output "db_master_secret_arn" {
  value = module.rds.master_secret_arn
}

output "service_secret_arns" {
  value = module.secrets.secret_arns
}

output "service_irsa_role_arns" {
  value = module.secrets.irsa_role_arns
}

output "assets_bucket" {
  value = module.storage.assets_bucket
}

output "reports_bucket" {
  value = module.storage.reports_bucket
}

output "ecr_repositories" {
  value = { for k, r in aws_ecr_repository.svc : k => r.repository_url }
}
