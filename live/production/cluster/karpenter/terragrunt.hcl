include "root" {
  path = find_in_parent_folders("root.hcl")
}

locals {
  env = read_terragrunt_config(find_in_parent_folders("env.hcl"))
}

terraform {
  source = "../../../../modules/cluster/karpenter"
}

inputs = {
  project_name = local.env.locals.project_name
  cluster_name = local.env.locals.cluster_name
  environment  = local.env.locals.environment
  tags         = { ManagedBy = "terraform" }
}
