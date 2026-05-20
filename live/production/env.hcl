locals {
  region       = "eu-west-1"
  project_name = "richman-aws-eks"
  environment  = "production"

  # Edit these before deploying:
  cluster_name       = "richman-production"
  kubernetes_version = "1.31"
  domain_name        = get_env("DOMAIN_NAME", "")       # your Route 53 domain
  admin_cidr         = get_env("TF_VAR_ADMIN_CIDR", "") # your IP/VPN CIDR for kubectl access

  # Availability zones — must be valid for the chosen region
  availability_zones = ["eu-west-1a", "eu-west-1b", "eu-west-1c"]
}
