# -----------------------------------------------------------------------------
# One root stack, instantiated per environment via:
#   -backend-config=envs/<env>.backend.hcl  (isolated state)
#   -var-file=envs/<env>.tfvars             (sizing/behaviour)
# -----------------------------------------------------------------------------

locals {
  name = "${var.project}-${var.environment}"

  tags = {
    Project     = var.project
    Environment = var.environment
    Owner       = var.owner
    CostCenter  = var.cost_center
    ManagedBy   = "terraform"
  }
}

module "network" {
  source = "../modules/network"

  name               = local.name
  vpc_cidr           = var.vpc_cidr
  azs                = var.azs
  single_nat_gateway = var.single_nat_gateway
  tags               = local.tags
}

module "eks" {
  source = "../modules/eks"

  name                   = local.name
  app_subnet_ids         = module.network.app_subnet_ids
  pci_subnet_ids         = module.network.pci_subnet_ids
  app_node_sg_id         = module.network.sg_app_nodes_id
  pci_node_sg_id         = module.network.sg_pci_nodes_id
  endpoint_public_access = var.eks_public_endpoint
  public_access_cidrs    = var.eks_public_access_cidrs
  app_node_group         = var.app_node_group
  pci_node_group         = var.pci_node_group
  batch_node_group       = var.batch_node_group
  tags                   = local.tags
}

module "rds" {
  source = "../modules/rds"

  name                  = local.name
  data_subnet_ids       = module.network.data_subnet_ids
  db_security_group_id  = module.network.sg_db_id
  instance_class        = var.db_instance_class
  allocated_storage_gb  = var.db_allocated_storage_gb
  multi_az              = var.db_multi_az
  backup_retention_days = var.db_backup_retention_days
  deletion_protection   = var.db_deletion_protection
  skip_final_snapshot   = var.environment == "dev"
  tags                  = local.tags
}

module "secrets" {
  source = "../modules/secrets"

  name              = local.name
  oidc_provider_arn = module.eks.oidc_provider_arn
  oidc_provider_url = module.eks.oidc_provider_url
  tags              = local.tags
}

module "storage" {
  source = "../modules/storage"

  name          = local.name
  force_destroy = var.force_destroy_buckets
  tags          = local.tags
}

# ECR repository per microservice (immutable tags + scan on push).
resource "aws_ecr_repository" "svc" {
  for_each             = toset(["order", "inventory", "payment"])
  name                 = "${var.project}/${each.key}"
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "KMS"
  }
}

resource "aws_ecr_lifecycle_policy" "svc" {
  for_each   = aws_ecr_repository.svc
  repository = each.value.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep last 30 images"
      selection    = { tagStatus = "any", countType = "imageCountMoreThan", countNumber = 30 }
      action       = { type = "expire" }
    }]
  })
}
