# Shared EKS cluster stack configuration.
# Include this from: live/<env>/cluster/eks/terragrunt.hcl
#
# find_in_parent_folders("env.hcl") resolves upward from the live file that includes
# this catalog, so it picks up the correct cluster's env.hcl automatically.

locals {
  env = read_terragrunt_config(find_in_parent_folders("env.hcl"))
  l   = local.env.locals

  vpc_id = trimspace(run_cmd("--terragrunt-quiet", "aws", "ssm", "get-parameter",
    "--name", "/${local.l.project_name}/${local.l.environment}/vpc/vpc-id",
    "--query", "Parameter.Value", "--output", "text"))

  private_subnet_0 = trimspace(run_cmd("--terragrunt-quiet", "aws", "ssm", "get-parameter",
    "--name", "/${local.l.project_name}/${local.l.environment}/vpc/private-subnet-0",
    "--query", "Parameter.Value", "--output", "text"))
  private_subnet_1 = trimspace(run_cmd("--terragrunt-quiet", "aws", "ssm", "get-parameter",
    "--name", "/${local.l.project_name}/${local.l.environment}/vpc/private-subnet-1",
    "--query", "Parameter.Value", "--output", "text"))
  private_subnet_2 = trimspace(run_cmd("--terragrunt-quiet", "aws", "ssm", "get-parameter",
    "--name", "/${local.l.project_name}/${local.l.environment}/vpc/private-subnet-2",
    "--query", "Parameter.Value", "--output", "text"))

  pod_subnet_0 = trimspace(run_cmd("--terragrunt-quiet", "aws", "ssm", "get-parameter",
    "--name", "/${local.l.project_name}/${local.l.environment}/vpc/pod-subnet-0",
    "--query", "Parameter.Value", "--output", "text"))
  pod_subnet_1 = trimspace(run_cmd("--terragrunt-quiet", "aws", "ssm", "get-parameter",
    "--name", "/${local.l.project_name}/${local.l.environment}/vpc/pod-subnet-1",
    "--query", "Parameter.Value", "--output", "text"))
  pod_subnet_2 = trimspace(run_cmd("--terragrunt-quiet", "aws", "ssm", "get-parameter",
    "--name", "/${local.l.project_name}/${local.l.environment}/vpc/pod-subnet-2",
    "--query", "Parameter.Value", "--output", "text"))

  account_id = trimspace(run_cmd("--terragrunt-quiet", "aws", "sts", "get-caller-identity",
    "--query", "Account", "--output", "text"))

  karpenter_controller_role_arn = trimspace(run_cmd("--terragrunt-quiet", "aws", "ssm", "get-parameter",
    "--name", "/${local.l.project_name}/${local.l.environment}/karpenter/controller-role-arn",
    "--query", "Parameter.Value", "--output", "text"))
}

terraform {
  source = "${get_repo_root()}/modules/cluster/eks"
}

inputs = {
  project_name       = local.l.project_name
  cluster_name       = local.l.cluster_name
  environment        = local.l.environment
  kubernetes_version = local.l.kubernetes_version
  admin_cidr         = local.l.admin_cidr
  availability_zones = local.l.availability_zones

  vpc_id             = local.vpc_id
  private_subnet_ids = [local.private_subnet_0, local.private_subnet_1, local.private_subnet_2]
  pod_subnet_ids     = [local.pod_subnet_0, local.pod_subnet_1, local.pod_subnet_2]

  addon_versions             = local.l.addon_versions
  eks_ami_release_version    = local.l.eks_ami_release_version
  system_node_instance_type  = local.l.system_node_instance_type
  system_node_desired        = local.l.system_node_desired
  system_node_min            = local.l.system_node_min
  system_node_max            = local.l.system_node_max

  pod_identity_associations = [
    { namespace = "kube-system",      service_account = "aws-load-balancer-controller", role_arn = "arn:aws:iam::${local.account_id}:role/${local.l.cluster_name}-aws-lbc" },
    { namespace = "external-dns",     service_account = "external-dns",                 role_arn = "arn:aws:iam::${local.account_id}:role/${local.l.cluster_name}-external-dns" },
    { namespace = "external-secrets", service_account = "external-secrets-sa",          role_arn = "arn:aws:iam::${local.account_id}:role/${local.l.cluster_name}-external-secrets" },
    { namespace = "kube-system",      service_account = "ebs-csi-controller-sa",        role_arn = "arn:aws:iam::${local.account_id}:role/${local.l.cluster_name}-ebs-csi" },
    { namespace = "velero",           service_account = "velero",                        role_arn = "arn:aws:iam::${local.account_id}:role/${local.l.cluster_name}-velero" },
    { namespace = "cloud-custodian",  service_account = "cloud-custodian",               role_arn = "arn:aws:iam::${local.account_id}:role/${local.l.cluster_name}-cloud-custodian" },
    { namespace = "monitoring",       service_account = "yace",                          role_arn = "arn:aws:iam::${local.account_id}:role/${local.l.cluster_name}-yace" },
    { namespace = "monitoring",       service_account = "noe",                           role_arn = "arn:aws:iam::${local.account_id}:role/${local.l.cluster_name}-noe" },
    { namespace = "karpenter",        service_account = "karpenter",                     role_arn = local.karpenter_controller_role_arn },
  ]

  tags = merge(local.l.tags, { ManagedBy = "terraform" })
}
