variable "project_name"       { type = string }
variable "cluster_name"       { type = string }
variable "environment"        { type = string }
variable "argocd_version"     { type = string; default = "7.7.0" }
variable "repo_url" {
  type        = string
  description = "Git repo URL for cluster-applications (your fork)."
  validation {
    condition     = var.repo_url != ""
    error_message = "repo_url must be set. Export REPO_URL=https://github.com/your-org/richman-aws-eks before applying."
  }
}
variable "domain_name"        { type = string; description = "Base domain. ArgoCD will be at argocd.<domain_name>." }
variable "region"             { type = string }
variable "account_id"         { type = string }
variable "vpc_id"             { type = string }
variable "private_subnet_ids" { type = list(string) }
variable "pod_subnet_ids"     { type = list(string) }
variable "availability_zones" { type = list(string) }
variable "nlb_sg_id"          { type = string }
variable "node_sg_id"         { type = string }
variable "tags"               { type = map(string); default = {} }
