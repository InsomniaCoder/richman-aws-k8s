variable "project_name" {
  type = string
}

variable "environment" {
  type = string
}

variable "cluster_name" {
  type        = string
  description = "EKS cluster name. Used to derive the CloudWatch log group name (/aws/eks/<cluster>/cluster)."
}

variable "lambda_promtail_image" {
  type        = string
  description = "OCI image URI for lambda-promtail. Published by Grafana at public.ecr.aws/grafana/lambda-promtail."
  default     = "public.ecr.aws/grafana/lambda-promtail:2.9.9"
}

variable "loki_write_address" {
  type        = string
  description = "Grafana Cloud Loki push endpoint, e.g. https://logs-prod-006.grafana.net/loki/api/v1/push"
}

variable "loki_username" {
  type        = string
  description = "Grafana Cloud Loki numeric user ID (basic auth username)."
}

variable "loki_password" {
  type        = string
  sensitive   = true
  description = "Grafana Cloud API key / token with Logs Push scope (basic auth password)."
}

variable "tags" {
  type    = map(string)
  default = {}
}
