variable "name" {
  type = string
}

variable "ia_transition_days" {
  type    = number
  default = 30
}

variable "glacier_ir_transition_days" {
  type    = number
  default = 90
}

variable "report_expiry_days" {
  description = "Delete generated nightly reports after this many days."
  type        = number
  default     = 365
}

variable "force_destroy" {
  description = "Allow destroying non-empty buckets (dev only)."
  type        = bool
  default     = false
}

variable "tags" {
  type    = map(string)
  default = {}
}
