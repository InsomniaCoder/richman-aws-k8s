# Shared IAM account stack configuration.
# Include this from: live/<env>/account/iam/terragrunt.hcl

locals {
  env = read_terragrunt_config(find_in_parent_folders("env.hcl"))
  l   = local.env.locals
}

terraform {
  source = "${get_repo_root()}/modules/account/iam"
}

inputs = {
  project_name = local.l.project_name
  environment  = local.l.environment
  tags         = merge(local.l.tags, { ManagedBy = "terraform" })
}
