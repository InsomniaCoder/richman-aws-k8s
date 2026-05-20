variable "project_name"    { type = string }
variable "environment"     { type = string }
variable "tags"            { type = map(string); default = {} }
variable "repositories"    {
  type        = list(string)
  default     = []
  description = "Application ECR repos to create. Platform images come via pull-through cache."
}
