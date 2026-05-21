variable "project_name"       { type = string }
variable "cluster_name"       { type = string }
variable "environment"        { type = string }
variable "kubernetes_version" { type = string }
variable "vpc_id"             { type = string }
variable "private_subnet_ids" { type = list(string) }
# AWS hard limit: max 40 CIDRs for EKS public API access.
variable "admin_cidrs" {
  type        = list(string)
  description = "CIDRs allowed to reach the EKS API server. Managed via live/<env>/admin-cidrs.json."
  validation {
    condition     = length(var.admin_cidrs) <= 40
    error_message = "AWS limits EKS public_access_cidrs to 40 entries."
  }
  validation {
    condition     = length(var.admin_cidrs) > 0
    error_message = "admin_cidrs must contain at least one CIDR. Populate live/<env>/admin-cidrs.json."
  }
}
variable "tags" { type = map(string); default = {} }
