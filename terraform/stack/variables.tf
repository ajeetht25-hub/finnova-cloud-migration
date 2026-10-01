variable "region" {
  type    = string
  default = "ap-south-1"
}

variable "environment" {
  description = "dev | staging | prod"
  type        = string

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be dev, staging or prod."
  }
}

variable "project" {
  type    = string
  default = "finnova"
}

variable "vpc_cidr" {
  type = string
}

variable "azs" {
  type = list(string)
}

variable "single_nat_gateway" {
  type    = bool
  default = false
}

variable "eks_public_endpoint" {
  type    = bool
  default = false
}

variable "eks_public_access_cidrs" {
  type    = list(string)
  default = []
}

variable "app_node_group" {
  type = object({
    instance_types = list(string)
    min_size       = number
    desired_size   = number
    max_size       = number
    capacity_type  = string
  })
}

variable "pci_node_group" {
  type = object({
    instance_types = list(string)
    min_size       = number
    desired_size   = number
    max_size       = number
  })
}

variable "batch_node_group" {
  type = object({
    instance_types = list(string)
    min_size       = number
    desired_size   = number
    max_size       = number
  })
}

variable "db_instance_class" {
  type = string
}

variable "db_allocated_storage_gb" {
  type = number
}

variable "db_multi_az" {
  type = bool
}

variable "db_backup_retention_days" {
  type = number
}

variable "db_deletion_protection" {
  type = bool
}

variable "force_destroy_buckets" {
  type    = bool
  default = false
}

variable "owner" {
  type    = string
  default = "platform-team"
}

variable "cost_center" {
  type    = string
  default = "order-management"
}
