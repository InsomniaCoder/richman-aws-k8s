data "aws_caller_identity" "current" {}

locals {
  common_tags = merge(var.tags, {
    Project     = var.project_name
    Environment = var.environment
  })
}

# ── EKS Cluster Role ──────────────────────────────────────────────────────────

resource "aws_iam_role" "eks_cluster" {
  name = "${var.project_name}-${var.environment}-eks-cluster-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "eks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "eks_cluster" {
  role       = aws_iam_role.eks_cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

# ── EKS Node Role ─────────────────────────────────────────────────────────────

resource "aws_iam_role" "eks_node" {
  name = "${var.project_name}-${var.environment}-eks-node-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "eks_node" {
  for_each = {
    worker    = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
    ecr       = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
    ssm       = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
    cni       = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
  }
  role       = aws_iam_role.eks_node.name
  policy_arn = each.value
}

# ECR pull-through cache — allows nodes to pull via ECR pull-through cache rules
resource "aws_iam_role_policy" "ecr_pull_through" {
  name = "ecr-pull-through-cache"
  role = aws_iam_role.eks_node.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "ecr:BatchImportUpstreamImage",
        "ecr:CreateRepository",
        "ecr:GetAuthorizationToken",
        "ecr:BatchGetImage",
        "ecr:GetDownloadUrlForLayer",
      ]
      Resource = "*"
    }]
  })
}

# Store role ARNs in SSM for consumption by cluster module
resource "aws_ssm_parameter" "node_role_arn" {
  name  = "/${var.project_name}/${var.environment}/iam/node-role-arn"
  type  = "String"
  value = aws_iam_role.eks_node.arn
}

resource "aws_ssm_parameter" "cluster_role_arn" {
  name  = "/${var.project_name}/${var.environment}/iam/cluster-role-arn"
  type  = "String"
  value = aws_iam_role.eks_cluster.arn
}
