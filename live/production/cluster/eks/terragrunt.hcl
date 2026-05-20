include "root" {
  path = find_in_parent_folders("root.hcl")
}

locals {
  env = read_terragrunt_config(find_in_parent_folders("env.hcl"))
  l   = local.env.locals

  # Read VPC outputs from SSM (written by account/vpc module)
  vpc_id = run_cmd("--terragrunt-quiet", "aws", "ssm", "get-parameter",
    "--name", "/${local.l.project_name}/${local.l.environment}/vpc/vpc-id",
    "--query", "Parameter.Value", "--output", "text")

  private_subnet_0 = run_cmd("--terragrunt-quiet", "aws", "ssm", "get-parameter",
    "--name", "/${local.l.project_name}/${local.l.environment}/vpc/private-subnet-0",
    "--query", "Parameter.Value", "--output", "text")

  private_subnet_1 = run_cmd("--terragrunt-quiet", "aws", "ssm", "get-parameter",
    "--name", "/${local.l.project_name}/${local.l.environment}/vpc/private-subnet-1",
    "--query", "Parameter.Value", "--output", "text")

  private_subnet_2 = run_cmd("--terragrunt-quiet", "aws", "ssm", "get-parameter",
    "--name", "/${local.l.project_name}/${local.l.environment}/vpc/private-subnet-2",
    "--query", "Parameter.Value", "--output", "text")

  pod_subnet_0 = run_cmd("--terragrunt-quiet", "aws", "ssm", "get-parameter",
    "--name", "/${local.l.project_name}/${local.l.environment}/vpc/pod-subnet-0",
    "--query", "Parameter.Value", "--output", "text")

  pod_subnet_1 = run_cmd("--terragrunt-quiet", "aws", "ssm", "get-parameter",
    "--name", "/${local.l.project_name}/${local.l.environment}/vpc/pod-subnet-1",
    "--query", "Parameter.Value", "--output", "text")

  pod_subnet_2 = run_cmd("--terragrunt-quiet", "aws", "ssm", "get-parameter",
    "--name", "/${local.l.project_name}/${local.l.environment}/vpc/pod-subnet-2",
    "--query", "Parameter.Value", "--output", "text")
}

terraform {
  source = "../../../../modules/cluster/eks"
}

inputs = {
  project_name       = local.l.project_name
  cluster_name       = local.l.cluster_name
  environment        = local.l.environment
  kubernetes_version = local.l.kubernetes_version
  admin_cidr         = local.l.admin_cidr
  availability_zones = local.l.availability_zones

  vpc_id             = trimspace(local.vpc_id)
  private_subnet_ids = [
    trimspace(local.private_subnet_0),
    trimspace(local.private_subnet_1),
    trimspace(local.private_subnet_2),
  ]
  pod_subnet_ids = [
    trimspace(local.pod_subnet_0),
    trimspace(local.pod_subnet_1),
    trimspace(local.pod_subnet_2),
  ]

  # Pin addon versions. Find latest:
  # aws eks describe-addon-versions --kubernetes-version 1.31 --query 'addons[].{name:addonName,version:addonVersions[0].addonVersion}'
  addon_versions = {
    vpc_cni      = "v1.19.0-eksbuild.1"
    kube_proxy   = "v1.31.2-eksbuild.3"
    coredns      = "v1.11.3-eksbuild.2"
    ebs_csi      = "v1.37.0-eksbuild.1"
    pod_identity = "v1.3.4-eksbuild.1"
  }

  eks_ami_release_version   = "1.31.4-20250123"
  system_node_instance_type = "m6i.xlarge"
  system_node_desired       = 2
  system_node_min           = 2
  system_node_max           = 4

  # Pod Identity associations — populated in Task 8 after addon IAM roles exist
  pod_identity_associations = []

  tags = { ManagedBy = "terraform" }
}
