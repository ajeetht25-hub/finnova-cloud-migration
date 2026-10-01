environment = "staging"
vpc_cidr    = "10.20.0.0/16"
azs         = ["ap-south-1a", "ap-south-1b"]

single_nat_gateway = true

app_node_group = {
  instance_types = ["m6i.large"]
  min_size       = 2
  desired_size   = 2
  max_size       = 4
  capacity_type  = "ON_DEMAND"
}

pci_node_group = {
  instance_types = ["m6i.large"]
  min_size       = 2
  desired_size   = 2
  max_size       = 3
}

batch_node_group = {
  instance_types = ["m6i.large", "m5.large"]
  min_size       = 0
  desired_size   = 0
  max_size       = 2
}

# Staging mirrors prod DB size/engine so cutover rehearsals are realistic.
db_instance_class        = "db.r6g.large"
db_allocated_storage_gb  = 1000
db_multi_az              = false
db_backup_retention_days = 7
db_deletion_protection   = true
