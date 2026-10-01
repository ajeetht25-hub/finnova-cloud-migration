environment = "prod"
vpc_cidr    = "10.30.0.0/16"
azs         = ["ap-south-1a", "ap-south-1b", "ap-south-1c"]

single_nat_gateway = false # one NAT per AZ for HA

eks_public_endpoint = false # API reachable only from inside the VPC / VPN

app_node_group = {
  instance_types = ["m6i.xlarge"]
  min_size       = 3
  desired_size   = 3
  max_size       = 12
  capacity_type  = "ON_DEMAND"
}

pci_node_group = {
  instance_types = ["m6i.large"]
  min_size       = 3
  desired_size   = 3
  max_size       = 6
}

batch_node_group = {
  instance_types = ["m6i.large", "m5.large", "m5a.large"]
  min_size       = 0
  desired_size   = 0
  max_size       = 4
}

db_instance_class        = "db.r6g.xlarge"
db_allocated_storage_gb  = 1000
db_multi_az              = true
db_backup_retention_days = 14
db_deletion_protection   = true
