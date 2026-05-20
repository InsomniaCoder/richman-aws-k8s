# Shared VPC account stack configuration.
# Include this from: live/<env>/account/vpc/terragrunt.hcl

locals {
  env = read_terragrunt_config(find_in_parent_folders("env.hcl"))
  l   = local.env.locals
}

terraform {
  source = "${get_repo_root()}/modules/account/vpc"
}

inputs = {
  project_name         = local.l.project_name
  environment          = local.l.environment
  availability_zones   = local.l.availability_zones
  single_nat_gateway   = try(local.l.single_nat_gateway, false)
  create_vpc_endpoints = try(local.l.create_vpc_endpoints, true)
  tags                 = merge(local.l.tags, { ManagedBy = "terraform" })
}
