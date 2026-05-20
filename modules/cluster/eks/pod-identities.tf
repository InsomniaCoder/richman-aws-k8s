# All AWS service account → IAM role mappings for Pod Identity.
# Add new entries here when adding a new service account that needs AWS access.
# For cross-account access where Pod Identity doesn't reach, see README: "Using IRSA".

variable "pod_identity_associations" {
  type = list(object({
    namespace       = string
    service_account = string
    role_arn        = string
  }))
  default     = []
  description = "List of Pod Identity associations. One per service account that needs AWS access."
}

resource "aws_eks_pod_identity_association" "main" {
  for_each = {
    for a in var.pod_identity_associations :
    "${a.namespace}/${a.service_account}" => a
  }
  cluster_name    = aws_eks_cluster.main.name
  namespace       = each.value.namespace
  service_account = each.value.service_account
  role_arn        = each.value.role_arn
  tags            = local.common_tags
}
