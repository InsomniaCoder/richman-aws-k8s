include "root" {
  path = find_in_parent_folders("root.hcl")
}

locals {
  env = read_terragrunt_config(find_in_parent_folders("env.hcl"))
}

terraform {
  source = "../../../../modules/account/vpc"
}

inputs = {
  project_name       = local.env.locals.project_name
  environment        = local.env.locals.environment
  availability_zones = local.env.locals.availability_zones
  single_nat_gateway = false
  create_vpc_endpoints = true
  tags = {
    ManagedBy = "terraform"
  }
}
