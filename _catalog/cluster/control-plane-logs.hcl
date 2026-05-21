# Shared control-plane log forwarding stack configuration.
# Include this from: live/<env>/cluster/control-plane-logs/terragrunt.hcl
#
# Subscribes the EKS control plane CloudWatch log group to a Lambda function
# (lambda-promtail) that ships logs to Grafana Cloud Loki.
#
# Prerequisites:
#   - The EKS cluster must exist (log group created by cluster/eks).
#   - Store Grafana Cloud credentials in SSM before apply:
#       /richman-aws-eks/production/grafana-cloud/loki-write-address
#       /richman-aws-eks/production/grafana-cloud/loki-username
#       /richman-aws-eks/production/grafana-cloud/loki-api-key
#
# The Loki credentials are read from SSM at plan/apply time (not baked into state).

locals {
  env = read_terragrunt_config(find_in_parent_folders("env.hcl"))
  l   = local.env.locals

  loki_write_address = trimspace(run_cmd("--terragrunt-quiet", "aws", "ssm", "get-parameter",
    "--name", "/${local.l.project_name}/${local.l.environment}/grafana-cloud/loki-write-address",
    "--with-decryption", "--query", "Parameter.Value", "--output", "text"))

  loki_username = trimspace(run_cmd("--terragrunt-quiet", "aws", "ssm", "get-parameter",
    "--name", "/${local.l.project_name}/${local.l.environment}/grafana-cloud/loki-username",
    "--query", "Parameter.Value", "--output", "text"))

  loki_password = trimspace(run_cmd("--terragrunt-quiet", "aws", "ssm", "get-parameter",
    "--name", "/${local.l.project_name}/${local.l.environment}/grafana-cloud/loki-api-key",
    "--with-decryption", "--query", "Parameter.Value", "--output", "text"))
}

terraform {
  source = "${get_repo_root()}/modules/cluster/control-plane-logs"
}

inputs = {
  project_name       = local.l.project_name
  environment        = local.l.environment
  cluster_name       = local.l.cluster_name
  loki_write_address = local.loki_write_address
  loki_username      = local.loki_username
  loki_password      = local.loki_password
  tags               = merge(local.l.tags, { ManagedBy = "terraform" })
}
