locals {
  common_tags = merge(var.tags, {
    Project     = var.project_name
    Environment = var.environment
  })
}

resource "aws_ecr_repository" "app" {
  for_each             = toset(var.repositories)
  name                 = each.value
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = local.common_tags
}

# Pull-through cache rules — mirror public registries through ECR
# Saves NAT bandwidth; nodes pull from ECR instead of public registries.
resource "aws_ecr_pull_through_cache_rule" "public_ecr" {
  ecr_repository_prefix = "public-ecr"
  upstream_registry_url = "public.ecr.aws"
}

resource "aws_ecr_pull_through_cache_rule" "dockerhub" {
  ecr_repository_prefix = "dockerhub"
  upstream_registry_url = "registry-1.docker.io"
  credential_arn        = var.dockerhub_secret_arn
}

resource "aws_ecr_pull_through_cache_rule" "quay" {
  ecr_repository_prefix = "quay"
  upstream_registry_url = "quay.io"
}

resource "aws_ecr_pull_through_cache_rule" "ghcr" {
  ecr_repository_prefix = "ghcr"
  upstream_registry_url = "ghcr.io"
  credential_arn        = var.ghcr_secret_arn
}
