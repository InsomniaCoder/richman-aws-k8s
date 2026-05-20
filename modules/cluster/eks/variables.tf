variable "project_name"       { type = string }
variable "cluster_name"       { type = string }
variable "environment"        { type = string }
variable "kubernetes_version" { type = string }
variable "vpc_id"             { type = string }
variable "private_subnet_ids" { type = list(string) }
# AWS hard limit: max 40 CIDRs for EKS public API access. Validated below.
variable "admin_cidr" {
  type        = string
  description = "CIDR allowed to reach kubectl (port 6443). Your IP or VPN CIDR."
  validation {
    condition     = length(split(",", var.admin_cidr)) <= 40
    error_message = "AWS limits EKS public_access_cidrs to 40 entries."
  }
}
variable "tags" { type = map(string); default = {} }
