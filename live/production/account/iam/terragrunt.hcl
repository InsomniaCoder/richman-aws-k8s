include "root" {
  path = find_in_parent_folders("root.hcl")
}

locals {
  env = read_terragrunt_config(find_in_parent_folders("env.hcl"))
}

terraform {
  source = "../../../../modules/account/iam"
}

inputs = {
  project_name = local.env.locals.project_name
  environment  = local.env.locals.environment
  tags         = { ManagedBy = "terraform" }
}
