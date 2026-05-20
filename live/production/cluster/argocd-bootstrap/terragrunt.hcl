include "root" {
  path = find_in_parent_folders("root.hcl")
}

locals {
  env = read_terragrunt_config(find_in_parent_folders("env.hcl"))
  l   = local.env.locals

  # Read from SSM (written by vpc + eks modules)
  vpc_id = trimspace(run_cmd("--terragrunt-quiet", "aws", "ssm", "get-parameter",
    "--name", "/${local.l.project_name}/${local.l.environment}/vpc/vpc-id",
    "--query", "Parameter.Value", "--output", "text"))

  private_subnet_0 = trimspace(run_cmd("--terragrunt-quiet", "aws", "ssm", "get-parameter",
    "--name", "/${local.l.project_name}/${local.l.environment}/vpc/private-subnet-0",
    "--query", "Parameter.Value", "--output", "text"))
  private_subnet_1 = trimspace(run_cmd("--terragrunt-quiet", "aws", "ssm", "get-parameter",
    "--name", "/${local.l.project_name}/${local.l.environment}/vpc/private-subnet-1",
    "--query", "Parameter.Value", "--output", "text"))
  private_subnet_2 = trimspace(run_cmd("--terragrunt-quiet", "aws", "ssm", "get-parameter",
    "--name", "/${local.l.project_name}/${local.l.environment}/vpc/private-subnet-2",
    "--query", "Parameter.Value", "--output", "text"))

  pod_subnet_0 = trimspace(run_cmd("--terragrunt-quiet", "aws", "ssm", "get-parameter",
    "--name", "/${local.l.project_name}/${local.l.environment}/vpc/pod-subnet-0",
    "--query", "Parameter.Value", "--output", "text"))
  pod_subnet_1 = trimspace(run_cmd("--terragrunt-quiet", "aws", "ssm", "get-parameter",
    "--name", "/${local.l.project_name}/${local.l.environment}/vpc/pod-subnet-1",
    "--query", "Parameter.Value", "--output", "text"))
  pod_subnet_2 = trimspace(run_cmd("--terragrunt-quiet", "aws", "ssm", "get-parameter",
    "--name", "/${local.l.project_name}/${local.l.environment}/vpc/pod-subnet-2",
    "--query", "Parameter.Value", "--output", "text"))

  nlb_sg_id = trimspace(run_cmd("--terragrunt-quiet", "aws", "ssm", "get-parameter",
    "--name", "/${local.l.project_name}/${local.l.environment}/cluster/nlb-sg-id",
    "--query", "Parameter.Value", "--output", "text"))
  node_sg_id = trimspace(run_cmd("--terragrunt-quiet", "aws", "ssm", "get-parameter",
    "--name", "/${local.l.project_name}/${local.l.environment}/cluster/node-sg-id",
    "--query", "Parameter.Value", "--output", "text"))

  cluster_endpoint = trimspace(run_cmd("--terragrunt-quiet", "aws", "ssm", "get-parameter",
    "--name", "/${local.l.project_name}/${local.l.environment}/cluster/endpoint",
    "--query", "Parameter.Value", "--output", "text"))
  cluster_ca = trimspace(run_cmd("--terragrunt-quiet", "aws", "ssm", "get-parameter",
    "--name", "/${local.l.project_name}/${local.l.environment}/cluster/ca",
    "--query", "Parameter.Value", "--output", "text"))

  account_id = trimspace(run_cmd("--terragrunt-quiet", "aws", "sts", "get-caller-identity",
    "--query", "Account", "--output", "text"))
}

# Generate helm provider configured for EKS
generate "helm_provider" {
  path      = "helm_provider.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<EOF
provider "helm" {
  kubernetes {
    host                   = "${local.cluster_endpoint}"
    cluster_ca_certificate = base64decode("${local.cluster_ca}")
    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", "${local.l.cluster_name}"]
    }
  }
}
EOF
}

# Generate kubernetes provider configured for EKS
generate "kubernetes_provider" {
  path      = "kubernetes_provider.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<EOF
provider "kubernetes" {
  host                   = "${local.cluster_endpoint}"
  cluster_ca_certificate = base64decode("${local.cluster_ca}")
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", "${local.l.cluster_name}"]
  }
}
EOF
}

terraform {
  source = "../../../../modules/cluster/argocd-bootstrap"
}

inputs = {
  project_name       = local.l.project_name
  cluster_name       = local.l.cluster_name
  environment        = local.l.environment
  region             = local.l.region
  domain_name        = local.l.domain_name
  availability_zones = local.l.availability_zones
  argocd_version     = "7.7.0"
  repo_url           = get_env("REPO_URL", "")
  account_id         = local.account_id

  vpc_id             = local.vpc_id
  private_subnet_ids = [local.private_subnet_0, local.private_subnet_1, local.private_subnet_2]
  pod_subnet_ids     = [local.pod_subnet_0, local.pod_subnet_1, local.pod_subnet_2]
  nlb_sg_id          = local.nlb_sg_id
  node_sg_id         = local.node_sg_id

  tags = { ManagedBy = "terraform" }
}
