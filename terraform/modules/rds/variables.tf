variable "name" {
  type = string
}

variable "data_subnet_ids" {
  description = "Private data-tier subnets (no internet route)."
  type        = list(string)
}

variable "db_security_group_id" {
  type = string
}

variable "engine_version" {
  type    = string
  default = "8.0.39"
}

variable "instance_class" {
  type    = string
  default = "db.r6g.large"
}

variable "allocated_storage_gb" {
  description = "Initial storage. 800 GB data + headroom."
  type        = number
  default     = 1000
}

variable "max_allocated_storage_gb" {
  description = "Storage autoscaling ceiling."
  type        = number
  default     = 2000
}

variable "multi_az" {
  type    = bool
  default = true
}

variable "backup_retention_days" {
  type    = number
  default = 14
}

variable "deletion_protection" {
  type    = bool
  default = true
}

variable "skip_final_snapshot" {
  type    = bool
  default = false
}

variable "performance_insights_enabled" {
  type    = bool
  default = true
}

variable "db_name" {
  description = "Initial schema. Service schemas are created by the migration."
  type        = string
  default     = "orders"
}

variable "tags" {
  type    = map(string)
  default = {}
}
