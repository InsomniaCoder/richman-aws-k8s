variable "addon_versions" {
  type = object({
    vpc_cni      = string
    kube_proxy   = string
    coredns      = string
    ebs_csi      = string
    pod_identity = string
  })
  description = "Pinned EKS managed addon versions. Find latest: aws eks describe-addon-versions --kubernetes-version <k8s_version>"
}

variable "pod_subnet_ids" {
  type        = list(string)
  description = "Dedicated pod subnets per AZ for VPC CNI custom networking (prefix delegation)."
}

variable "availability_zones" {
  type = list(string)
}

# VPC CNI — prefix delegation + custom networking + NetworkPolicy enforcement
resource "aws_eks_addon" "vpc_cni" {
  cluster_name                = aws_eks_cluster.main.name
  addon_name                  = "vpc-cni"
  addon_version               = var.addon_versions.vpc_cni
  resolve_conflicts_on_update = "OVERWRITE"
  resolve_conflicts_on_create = "OVERWRITE"

  configuration_values = jsonencode({
    env = {
      ENABLE_PREFIX_DELEGATION           = "true"
      AWS_VPC_K8S_CNI_CUSTOM_NETWORK_CFG = "true"
      # Select ENIConfig by node AZ label
      ENI_CONFIG_LABEL_DEF               = "topology.kubernetes.io/zone"
      # Enable VPC CNI native NetworkPolicy enforcement (no Calico needed)
      NETWORK_POLICY_ENFORCING_MODE      = "standard"
    }
    # Create ENIConfig CRs — one per AZ pointing at pod subnet
    eniConfig = {
      create = true
      region = data.aws_region.current.name
      subnets = {
        for i, az in var.availability_zones :
        az => {
          id             = var.pod_subnet_ids[i]
          securityGroups = [aws_security_group.nodes.id]
        }
      }
    }
  })

  depends_on = [aws_eks_cluster.main]
  tags       = local.common_tags

  timeouts {
    create = "30m"
    update = "30m"
    delete = "30m"
  }
}

data "aws_region" "current" {}

resource "aws_eks_addon" "kube_proxy" {
  cluster_name                = aws_eks_cluster.main.name
  addon_name                  = "kube-proxy"
  addon_version               = var.addon_versions.kube_proxy
  resolve_conflicts_on_update = "OVERWRITE"
  depends_on                  = [aws_eks_cluster.main]
  tags                        = local.common_tags
}

resource "aws_eks_addon" "coredns" {
  cluster_name                = aws_eks_cluster.main.name
  addon_name                  = "coredns"
  addon_version               = var.addon_versions.coredns
  resolve_conflicts_on_update = "OVERWRITE"
  depends_on                  = [aws_eks_node_group.system]
  tags                        = local.common_tags
}

resource "aws_eks_addon" "ebs_csi" {
  cluster_name                = aws_eks_cluster.main.name
  addon_name                  = "aws-ebs-csi-driver"
  addon_version               = var.addon_versions.ebs_csi
  resolve_conflicts_on_update = "OVERWRITE"
  depends_on                  = [aws_eks_cluster.main]
  tags                        = local.common_tags
}

resource "aws_eks_addon" "pod_identity" {
  cluster_name  = aws_eks_cluster.main.name
  addon_name    = "eks-pod-identity-agent"
  addon_version = var.addon_versions.pod_identity
  resolve_conflicts_on_update = "OVERWRITE"

  # Must tolerate system node taint to run on system nodes
  configuration_values = jsonencode({
    tolerations = [{
      key    = "system-node"
      value  = "true"
      effect = "NoSchedule"
    }]
  })

  depends_on = [aws_eks_node_group.system]
  tags       = local.common_tags
}
