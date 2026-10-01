variable "name" {
  description = "Name prefix for all resources (e.g. finnova-prod)."
  type        = string
}

variable "vpc_cidr" {
  description = "VPC CIDR block."
  type        = string
  default     = "10.20.0.0/16"
}

variable "azs" {
  description = "Availability zones to use (2 or 3)."
  type        = list(string)
}

variable "single_nat_gateway" {
  description = "Use one NAT gateway (dev/staging cost saving) instead of one per AZ (prod HA)."
  type        = bool
  default     = false
}

variable "flow_log_retention_days" {
  description = "Retention for VPC flow logs in CloudWatch."
  type        = number
  default     = 90
}

variable "tags" {
  type    = map(string)
  default = {}
}
