variable "name" {
  type = string
}

variable "kubernetes_version" {
  type    = string
  default = "1.31"
}

variable "app_subnet_ids" {
  description = "Private subnets for general worker nodes."
  type        = list(string)
}

variable "pci_subnet_ids" {
  description = "Isolated private subnets for PCI worker nodes (payment service)."
  type        = list(string)
}

variable "app_node_sg_id" {
  type = string
}

variable "pci_node_sg_id" {
  type = string
}

variable "endpoint_public_access" {
  description = "Expose the API endpoint publicly. Keep false in prod; use VPN/bastion/CI runner in VPC."
  type        = bool
  default     = false
}

variable "public_access_cidrs" {
  description = "Allowed CIDRs if endpoint_public_access is true (never 0.0.0.0/0 in prod)."
  type        = list(string)
  default     = []
}

variable "app_node_group" {
  description = "Sizing for the general node group."
  type = object({
    instance_types = list(string)
    min_size       = number
    desired_size   = number
    max_size       = number
    capacity_type  = string
  })
  default = {
    instance_types = ["m6i.large"]
    min_size       = 2
    desired_size   = 2
    max_size       = 6
    capacity_type  = "ON_DEMAND"
  }
}

variable "pci_node_group" {
  description = "Sizing for the dedicated PCI node group. Always ON_DEMAND."
  type = object({
    instance_types = list(string)
    min_size       = number
    desired_size   = number
    max_size       = number
  })
  default = {
    instance_types = ["m6i.large"]
    min_size       = 2
    desired_size   = 2
    max_size       = 4
  }
}

variable "batch_node_group" {
  description = "Spot node group for nightly batch CronJobs. Set max_size = 0 to disable."
  type = object({
    instance_types = list(string)
    min_size       = number
    desired_size   = number
    max_size       = number
  })
  default = {
    instance_types = ["m6i.large", "m5.large", "m5a.large"]
    min_size       = 0
    desired_size   = 0
    max_size       = 4
  }
}

variable "log_retention_days" {
  type    = number
  default = 90
}

variable "tags" {
  type    = map(string)
  default = {}
}
