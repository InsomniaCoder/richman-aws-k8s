include "root" {
  path = find_in_parent_folders("root.hcl")
}

locals {
  env = read_terragrunt_config(find_in_parent_folders("env.hcl"))
}

terraform {
  source = "../../../../modules/account/ecr"
}

inputs = {
  project_name = local.env.locals.project_name
  environment  = local.env.locals.environment
  repositories = []   # add application repo names here
  tags         = { ManagedBy = "terraform" }
}
