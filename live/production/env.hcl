# Everything that makes this environment/cluster unique.
# This is the ONLY file you edit to define a new cluster.
# All stack logic lives in _catalog/; these values flow in automatically.

locals {
  region       = "eu-west-1"
  project_name = "richman-aws-eks"
  environment  = "production"

  # Edit these before deploying:
  cluster_name       = "richman-production"
  kubernetes_version = "1.31"
  domain_name        = get_env("DOMAIN_NAME", "")        # your Route 53 domain
  admin_cidr         = get_env("TF_VAR_ADMIN_CIDR", "")  # your IP/VPN CIDR for kubectl access

  # Availability zones — must be valid for the chosen region
  availability_zones = ["eu-west-1a", "eu-west-1b", "eu-west-1c"]

  # VPC configuration — set single_nat_gateway = true for cost-sensitive environments
  single_nat_gateway   = false
  create_vpc_endpoints = true

  # ECR repos to create for this environment (application image repos)
  ecr_repositories = []

  # EKS system node group
  system_node_instance_type = "m6i.xlarge"
  system_node_desired       = 2
  system_node_min           = 2
  system_node_max           = 4
  eks_ami_release_version   = "1.31.4-20250123"

  # EKS managed addon versions. Find latest:
  # aws eks describe-addon-versions --kubernetes-version 1.31
  addon_versions = {
    vpc_cni      = "v1.19.0-eksbuild.1"
    kube_proxy   = "v1.31.2-eksbuild.3"
    coredns      = "v1.11.3-eksbuild.2"
    ebs_csi      = "v1.37.0-eksbuild.1"
    pod_identity = "v1.3.4-eksbuild.1"
  }

  # ArgoCD Helm chart version
  argocd_version = "7.7.0"

  # Common tags applied to all Terraform-managed resources
  tags = {
    Project     = "richman-aws-eks"
    Environment = "production"
  }
}
