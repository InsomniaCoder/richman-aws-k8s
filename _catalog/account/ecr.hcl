# Shared ECR account stack configuration.
# Include this from: live/<env>/account/ecr/terragrunt.hcl

locals {
  env = read_terragrunt_config(find_in_parent_folders("env.hcl"))
  l   = local.env.locals
}

terraform {
  source = "${get_repo_root()}/modules/account/ecr"
}

inputs = {
  project_name = local.l.project_name
  environment  = local.l.environment
  repositories = try(local.l.ecr_repositories, [])
  tags         = merge(local.l.tags, { ManagedBy = "terraform" })
}
