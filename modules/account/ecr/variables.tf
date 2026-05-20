variable "project_name"    { type = string }
variable "environment"     { type = string }
variable "tags"            { type = map(string); default = {} }
variable "repositories"    {
  type        = list(string)
  default     = []
  description = "Application ECR repos to create. Platform images come via pull-through cache."
}
variable "dockerhub_secret_arn" {
  type        = string
  default     = null
  description = "Secrets Manager ARN for DockerHub credentials. Required for pull-through cache to work past anonymous rate limits."
}
variable "ghcr_secret_arn" {
  type        = string
  default     = null
  description = "Secrets Manager ARN for GHCR credentials. Required for pull-through cache to work past anonymous rate limits."
}
