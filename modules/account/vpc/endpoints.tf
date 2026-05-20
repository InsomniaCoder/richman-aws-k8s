locals {
  endpoint_services = var.create_vpc_endpoints ? {
    "s3"              = { type = "Gateway", private_dns = false }
    "ecr.api"         = { type = "Interface", private_dns = true }
    "ecr.dkr"         = { type = "Interface", private_dns = true }
    "secretsmanager"  = { type = "Interface", private_dns = true }
    "ssm"             = { type = "Interface", private_dns = true }
    "ssmmessages"     = { type = "Interface", private_dns = true }
    "ec2messages"     = { type = "Interface", private_dns = true }
    "sts"             = { type = "Interface", private_dns = true }
    "ec2"             = { type = "Interface", private_dns = true }
  } : {}

  gateway_endpoints   = { for k, v in local.endpoint_services : k => v if v.type == "Gateway" }
  interface_endpoints = { for k, v in local.endpoint_services : k => v if v.type == "Interface" }
}

resource "aws_security_group" "vpc_endpoints" {
  count       = var.create_vpc_endpoints ? 1 : 0
  name        = "${var.project_name}-vpc-endpoints-sg"
  description = "Allow HTTPS from VPC to interface endpoints"
  vpc_id      = aws_vpc.main.id
  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }
  tags = merge(local.common_tags, { Name = "${var.project_name}-vpc-endpoints-sg" })
}

resource "aws_vpc_endpoint" "gateway" {
  for_each        = local.gateway_endpoints
  vpc_id          = aws_vpc.main.id
  service_name    = "com.amazonaws.${data.aws_region.current.name}.${each.key}"
  vpc_endpoint_type = "Gateway"
  route_table_ids = concat(
    [aws_route_table.public.id],
    aws_route_table.private[*].id
  )
  tags = merge(local.common_tags, { Name = "${var.project_name}-endpoint-${each.key}" })
}

resource "aws_vpc_endpoint" "interface" {
  for_each            = local.interface_endpoints
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${data.aws_region.current.name}.${each.key}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [aws_security_group.vpc_endpoints[0].id]
  private_dns_enabled = each.value.private_dns
  tags                = merge(local.common_tags, { Name = "${var.project_name}-endpoint-${each.key}" })
}

data "aws_region" "current" {}
