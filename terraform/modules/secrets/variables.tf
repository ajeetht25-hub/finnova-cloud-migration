variable "name" {
  type = string
}

variable "services" {
  description = "Per-service secrets to create (order, inventory, payment). Values are set out-of-band, never in Terraform."
  type        = list(string)
  default     = ["order", "inventory", "payment"]
}

variable "oidc_provider_arn" {
  type = string
}

variable "oidc_provider_url" {
  description = "OIDC issuer without https://"
  type        = string
}

variable "k8s_namespace" {
  type    = string
  default = "orders"
}

variable "pci_namespace" {
  type    = string
  default = "payments"
}

variable "recovery_window_days" {
  type    = number
  default = 7
}

variable "tags" {
  type    = map(string)
  default = {}
}
