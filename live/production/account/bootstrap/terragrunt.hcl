# Bootstrap uses local backend — no S3 bucket yet.
# Run ONCE before all other stacks:
#   cd live/production/account/bootstrap && terragrunt apply
terraform {
  source = "../../../../modules/account/bootstrap"
  extra_arguments "local_backend" {
    commands = ["init", "plan", "apply"]
    arguments = ["-backend=false"]
  }
}

locals {
  env = read_terragrunt_config(find_in_parent_folders("env.hcl"))
}

inputs = {
  project_name = local.env.locals.project_name
  region       = local.env.locals.region
}
