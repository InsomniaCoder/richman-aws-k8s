# Shared Karpenter cluster stack configuration.
# Include this from: live/<env>/cluster/karpenter/terragrunt.hcl

locals {
  env = read_terragrunt_config(find_in_parent_folders("env.hcl"))
  l   = local.env.locals
}

terraform {
  source = "${get_repo_root()}/modules/cluster/karpenter"
}

inputs = {
  project_name = local.l.project_name
  cluster_name = local.l.cluster_name
  environment  = local.l.environment
  tags         = merge(local.l.tags, { ManagedBy = "terraform" })
}
