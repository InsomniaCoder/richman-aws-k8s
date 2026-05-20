data "aws_caller_identity" "current" {}
data "aws_iam_roles" "sso_admin" {
  name_regex = "^AWSReservedSSO_admin_.*"
}

data "aws_ssm_parameter" "cluster_role_arn" {
  name = "/${var.project_name}/${var.environment}/iam/cluster-role-arn"
}
data "aws_ssm_parameter" "node_role_arn" {
  name = "/${var.project_name}/${var.environment}/iam/node-role-arn"
}

resource "aws_cloudwatch_log_group" "cluster" {
  name              = "/aws/eks/${var.cluster_name}/cluster"
  retention_in_days = 30
  tags              = local.common_tags
}

resource "aws_eks_cluster" "main" {
  name     = var.cluster_name
  role_arn = data.aws_ssm_parameter.cluster_role_arn.value
  version  = var.kubernetes_version

  bootstrap_self_managed_addons = false

  vpc_config {
    subnet_ids              = var.private_subnet_ids
    security_group_ids      = [aws_security_group.control_plane.id]
    endpoint_private_access = true
    endpoint_public_access  = true
    public_access_cidrs     = split(",", var.admin_cidr)
  }

  access_config {
    authentication_mode                         = "API_AND_CONFIG_MAP"
    bootstrap_cluster_creator_admin_permissions = true
  }

  enabled_cluster_log_types = ["api", "audit", "authenticator", "controllerManager", "scheduler"]

  depends_on = [aws_cloudwatch_log_group.cluster]
  tags       = local.common_tags

  lifecycle { prevent_destroy = true }
}

# Grant SSO admin roles cluster-admin access via EKS access entries (not aws-auth ConfigMap)
resource "aws_eks_access_entry" "sso_admin" {
  for_each      = toset(data.aws_iam_roles.sso_admin.arns)
  cluster_name  = aws_eks_cluster.main.name
  principal_arn = each.value
  tags          = local.common_tags
}

resource "aws_eks_access_policy_association" "sso_admin" {
  for_each      = toset(data.aws_iam_roles.sso_admin.arns)
  cluster_name  = aws_eks_cluster.main.name
  principal_arn = each.value
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
  access_scope  { type = "cluster" }
  depends_on    = [aws_eks_access_entry.sso_admin]
}

# Node group access entry — allows nodes to register
resource "aws_eks_access_entry" "nodes" {
  cluster_name  = aws_eks_cluster.main.name
  principal_arn = data.aws_ssm_parameter.node_role_arn.value
  type          = "EC2_LINUX"
  tags          = local.common_tags
}

# Store cluster outputs in SSM for karpenter + argocd-bootstrap modules
resource "aws_ssm_parameter" "cluster_name" {
  name  = "/${var.project_name}/${var.environment}/cluster/name"
  type  = "String"
  value = aws_eks_cluster.main.name
  tags  = local.common_tags
}

resource "aws_ssm_parameter" "cluster_endpoint" {
  name  = "/${var.project_name}/${var.environment}/cluster/endpoint"
  type  = "String"
  value = aws_eks_cluster.main.endpoint
  tags  = local.common_tags
}

resource "aws_ssm_parameter" "cluster_ca" {
  name  = "/${var.project_name}/${var.environment}/cluster/ca"
  type  = "String"
  value = aws_eks_cluster.main.certificate_authority[0].data
  tags  = local.common_tags
}
