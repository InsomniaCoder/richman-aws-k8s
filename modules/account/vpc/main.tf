locals {
  # 3 AZs × 3 tiers (public/private/pod)
  # Public:  10.0.{0,1,2}.0/24     (one per AZ — for NLB/ALB and NAT GW)
  # Private: 10.0.{10,11,12}.0/24  (one per AZ — for nodes)
  # Pod:     10.0.{64,128,192}.0/18 (one per AZ — for pod IPs via VPC CNI)
  az_count      = length(var.availability_zones)
  public_cidrs  = [for i in range(local.az_count) : cidrsubnet(var.vpc_cidr, 8, i)]
  private_cidrs = [for i in range(local.az_count) : cidrsubnet(var.vpc_cidr, 8, 10 + i)]
  pod_cidrs     = [for i in range(local.az_count) : cidrsubnet(var.vpc_cidr, 2, 1 + i)]

  common_tags = merge(var.tags, {
    Project     = var.project_name
    Environment = var.environment
  })
}

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = merge(local.common_tags, { Name = "${var.project_name}-vpc" })
}

resource "aws_subnet" "public" {
  count                   = local.az_count
  vpc_id                  = aws_vpc.main.id
  cidr_block              = local.public_cidrs[count.index]
  availability_zone       = var.availability_zones[count.index]
  map_public_ip_on_launch = true
  tags = merge(local.common_tags, {
    Name                                                = "${var.project_name}-public-${var.availability_zones[count.index]}"
    "kubernetes.io/role/elb"                            = "1"
    "kubernetes.io/cluster/${var.project_name}-cluster" = "shared"
  })
}

resource "aws_subnet" "private" {
  count             = local.az_count
  vpc_id            = aws_vpc.main.id
  cidr_block        = local.private_cidrs[count.index]
  availability_zone = var.availability_zones[count.index]
  tags = merge(local.common_tags, {
    Name                                                = "${var.project_name}-private-${var.availability_zones[count.index]}"
    "kubernetes.io/role/internal-elb"                   = "1"
    "kubernetes.io/cluster/${var.project_name}-cluster" = "shared"
  })
}

resource "aws_subnet" "pod" {
  count             = local.az_count
  vpc_id            = aws_vpc.main.id
  cidr_block        = local.pod_cidrs[count.index]
  availability_zone = var.availability_zones[count.index]
  tags = merge(local.common_tags, {
    Name                              = "${var.project_name}-pod-${var.availability_zones[count.index]}"
    # Used by VPC CNI ENI_CONFIG_LABEL_DEF to select the right subnet per AZ
    "topology.kubernetes.io/zone"     = var.availability_zones[count.index]
  })
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = merge(local.common_tags, { Name = "${var.project_name}-igw" })
}

resource "aws_eip" "nat" {
  count  = var.single_nat_gateway ? 1 : local.az_count
  domain = "vpc"
  tags   = merge(local.common_tags, { Name = "${var.project_name}-nat-eip-${count.index}" })
}

resource "aws_nat_gateway" "main" {
  count         = var.single_nat_gateway ? 1 : local.az_count
  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[count.index].id
  tags          = merge(local.common_tags, { Name = "${var.project_name}-nat-${count.index}" })
  depends_on    = [aws_internet_gateway.main]
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }
  tags = merge(local.common_tags, { Name = "${var.project_name}-public-rt" })
}

resource "aws_route_table_association" "public" {
  count          = local.az_count
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table" "private" {
  count  = local.az_count
  vpc_id = aws_vpc.main.id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = var.single_nat_gateway ? aws_nat_gateway.main[0].id : aws_nat_gateway.main[count.index].id
  }
  tags = merge(local.common_tags, { Name = "${var.project_name}-private-rt-${count.index}" })
}

resource "aws_route_table_association" "private" {
  count          = local.az_count
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}

# Pod subnets share the private route table (same egress path as nodes)
resource "aws_route_table_association" "pod" {
  count          = local.az_count
  subnet_id      = aws_subnet.pod[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}

# Store subnet IDs in SSM so cluster module can consume them without Terragrunt dependencies
resource "aws_ssm_parameter" "public_subnet_ids" {
  count = local.az_count
  name  = "/${var.project_name}/${var.environment}/vpc/public-subnet-${count.index}"
  type  = "String"
  value = aws_subnet.public[count.index].id
}

resource "aws_ssm_parameter" "private_subnet_ids" {
  count = local.az_count
  name  = "/${var.project_name}/${var.environment}/vpc/private-subnet-${count.index}"
  type  = "String"
  value = aws_subnet.private[count.index].id
}

resource "aws_ssm_parameter" "pod_subnet_ids" {
  count = local.az_count
  name  = "/${var.project_name}/${var.environment}/vpc/pod-subnet-${count.index}"
  type  = "String"
  value = aws_subnet.pod[count.index].id
}

resource "aws_ssm_parameter" "vpc_id" {
  name  = "/${var.project_name}/${var.environment}/vpc/vpc-id"
  type  = "String"
  value = aws_vpc.main.id
}
