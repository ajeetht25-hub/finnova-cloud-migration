environment = "dev"
vpc_cidr    = "10.10.0.0/16"
azs         = ["ap-south-1a", "ap-south-1b"]

single_nat_gateway = true # cost: one NAT is fine for dev

app_node_group = {
  instance_types = ["t3.large"]
  min_size       = 1
  desired_size   = 2
  max_size       = 3
  capacity_type  = "SPOT"
}

pci_node_group = {
  instance_types = ["t3.large"]
  min_size       = 1
  desired_size   = 1
  max_size       = 2
}

batch_node_group = {
  instance_types = ["t3.large"]
  min_size       = 0
  desired_size   = 0
  max_size       = 0 # batch group disabled in dev
}

db_instance_class        = "db.t4g.medium"
db_allocated_storage_gb  = 100
db_multi_az              = false
db_backup_retention_days = 3
db_deletion_protection   = false
force_destroy_buckets    = true
