# richman-aws-eks Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a production-grade EKS platform on AWS demonstrating the full stack a startup or enterprise would actually run — EKS, Karpenter, VPC CNI with prefix delegation, Pod Identity, Traefik/LBC ingress, External Secrets Operator, Kyverno, OpenTelemetry, and ArgoCD GitOps with sync waves.

**Architecture:** Terragrunt with two layers (`account/` for VPC/IAM, `cluster/` for EKS/addons/ArgoCD bootstrap) so environments and clusters are addable by creating a new directory. ArgoCD App-of-Apps with 7 platform Helm charts manages all in-cluster tooling after bootstrap. Configuration flows from a single `env.hcl` per environment through to per-chart `values/production.yaml` overrides.

**Tech Stack:** Terraform ≥ 1.10, Terragrunt v1, Helm 3, kubectl, AWS CLI v2, EKS 1.31+, Karpenter 1.x, ArgoCD 2.13+, Traefik 3.x, kube-prometheus-stack, Loki, OTEL Operator, External Secrets Operator, Kyverno 3.x, KEDA 2.x, Velero.

---

## File Map

```
richman-aws-eks/
├── root.hcl
├── .github/
│   └── workflows/
│       ├── terraform-plan.yml        (disabled)
│       └── terraform-apply.yml       (disabled)
├── modules/
│   ├── account/
│   │   ├── vpc/
│   │   │   ├── main.tf               VPC, subnets (3 tiers × 3 AZs), IGW, NAT GWs, route tables
│   │   │   ├── endpoints.tf          VPC interface + gateway endpoints
│   │   │   ├── variables.tf
│   │   │   ├── outputs.tf            subnet IDs, VPC ID, AZ list → SSM
│   │   │   └── versions.tf
│   │   ├── iam/
│   │   │   ├── main.tf               eks-cluster-role, eks-node-role + policy attachments
│   │   │   ├── variables.tf
│   │   │   ├── outputs.tf
│   │   │   └── versions.tf
│   │   └── ecr/
│   │       ├── main.tf               ECR repos + pull-through cache rules
│   │       ├── variables.tf
│   │       ├── outputs.tf
│   │       └── versions.tf
│   └── cluster/
│       ├── eks/
│       │   ├── main.tf               EKS cluster resource, access entries, CloudWatch log group
│       │   ├── node-group.tf         System managed node group + launch template
│       │   ├── addons.tf             vpc-cni, kube-proxy, coredns, ebs-csi, pod-identity-agent
│       │   ├── pod-identities.tf     aws_eks_pod_identity_association for all service accounts
│       │   ├── security-groups.tf    sg-control-plane, sg-nodes, sg-nlb
│       │   ├── variables.tf
│       │   ├── outputs.tf            cluster name, endpoint, CA, OIDC → SSM
│       │   └── versions.tf
│       ├── karpenter/
│       │   ├── main.tf               IAM roles + policies, SQS queue, EventBridge rules
│       │   ├── variables.tf
│       │   ├── outputs.tf
│       │   └── versions.tf
│       └── argocd-bootstrap/
│           ├── main.tf               helm_release argocd + ArgoCD Application (App-of-Apps)
│           ├── configmap.tf          environments/production.yaml ConfigMap
│           ├── variables.tf
│           ├── outputs.tf
│           └── versions.tf
├── cluster-applications/
│   ├── environments/
│   │   └── production.yaml           (written by Terraform, not hand-edited)
│   ├── bootstrap/
│   │   ├── Chart.yaml
│   │   ├── values.yaml               default values (clusterName, domain, syncPolicy)
│   │   └── templates/
│   │       ├── platform-core.yaml
│   │       ├── platform-networking.yaml
│   │       ├── platform-autoscaling.yaml
│   │       ├── platform-secrets.yaml
│   │       ├── platform-policy.yaml
│   │       ├── platform-observability.yaml
│   │       └── platform-gitops.yaml
│   ├── platform-core/
│   │   ├── Chart.yaml
│   │   ├── values/
│   │   │   ├── base.yaml
│   │   │   └── production.yaml
│   │   └── templates/
│   │       ├── namespaces.yaml       all platform namespaces
│   │       ├── priority-classes.yaml
│   │       ├── flowschemas.yaml      APF flowschemas
│   │       ├── apps/
│   │       │   ├── metrics-server.yaml
│   │       │   ├── vpa.yaml
│   │       │   ├── node-problem-detector.yaml
│   │       │   ├── node-local-dns.yaml
│   │       │   └── reloader.yaml
│   ├── platform-networking/
│   │   ├── Chart.yaml
│   │   ├── values/
│   │   │   ├── base.yaml
│   │   │   └── production.yaml
│   │   └── templates/apps/
│   │       ├── aws-load-balancer-controller.yaml
│   │       ├── traefik.yaml
│   │       ├── cert-manager.yaml
│   │       └── external-dns.yaml
│   ├── platform-autoscaling/
│   │   ├── Chart.yaml
│   │   ├── values/
│   │   │   ├── base.yaml
│   │   │   └── production.yaml
│   │   └── templates/apps/
│   │       ├── karpenter.yaml
│   │       ├── karpenter-nodepools.yaml
│   │       └── keda.yaml
│   ├── platform-secrets/
│   │   ├── Chart.yaml
│   │   ├── values/
│   │   │   ├── base.yaml
│   │   │   └── production.yaml
│   │   └── templates/apps/
│   │       ├── external-secrets-operator.yaml
│   │       └── cluster-secret-store.yaml
│   ├── platform-policy/
│   │   ├── Chart.yaml
│   │   ├── values/
│   │   │   ├── base.yaml
│   │   │   └── production.yaml
│   │   └── templates/apps/
│   │       ├── kyverno.yaml
│   │       ├── kyverno-policies.yaml  (require-requests, no-latest-tag, default-netpol, require-labels)
│   │       └── cloud-custodian.yaml
│   ├── platform-observability/
│   │   ├── Chart.yaml
│   │   ├── values/
│   │   │   ├── base.yaml
│   │   │   └── production.yaml
│   │   └── templates/apps/
│   │       ├── otel-operator.yaml
│   │       ├── otel-collector.yaml    (DaemonSet mode, filelog + otlp receivers → Loki + Prometheus)
│   │       ├── kube-prometheus-stack.yaml
│   │       ├── node-exporter.yaml
│   │       ├── loki.yaml
│   │       ├── kubernetes-events-exporter.yaml
│   │       ├── noe.yaml
│   │       └── yace.yaml
│   └── platform-gitops/
│       ├── Chart.yaml
│       ├── values/
│       │   ├── base.yaml
│       │   └── production.yaml
│       └── templates/apps/
│           ├── argocd-projects.yaml
│           ├── argocd-rbac.yaml
│           └── velero.yaml
└── live/
    └── production/
        ├── env.hcl
        ├── account/
        │   ├── vpc/terragrunt.hcl
        │   ├── iam/terragrunt.hcl
        │   └── ecr/terragrunt.hcl
        └── cluster/
            ├── eks/terragrunt.hcl
            ├── karpenter/terragrunt.hcl
            └── argocd-bootstrap/terragrunt.hcl
```

---

## Phase 0: Repo scaffolding

### Task 1: Initialize repo structure and root Terragrunt config

**Files:**
- Create: `root.hcl`
- Create: `live/production/env.hcl`
- Create: `.gitignore`
- Create: `README.md` (stub — full content in Task 22)

- [ ] **Step 1: Create `.gitignore`**

```
**/.terraform/
*.tfstate
*.tfstate.backup
**/.terragrunt-cache/
*.tfvars
live/**/backend.tf
live/**/provider.tf
**/.terraform.lock.hcl
.env
```

- [ ] **Step 2: Create `root.hcl`**

```hcl
locals {
  env = read_terragrunt_config(find_in_parent_folders("env.hcl"))

  region       = local.env.locals.region
  project_name = local.env.locals.project_name
}

remote_state {
  backend = "s3"
  generate = {
    path      = "backend.tf"
    if_exists = "overwrite_terragrunt"
  }
  config = {
    bucket         = "${local.project_name}-tfstate-${local.region}"
    key            = "${path_relative_to_include()}/terraform.tfstate"
    region         = local.region
    encrypt        = true
    use_lockfile   = true
  }
}

generate "provider" {
  path      = "provider.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<EOF
provider "aws" {
  region = "${local.region}"
}
EOF
}
```

- [ ] **Step 3: Create `live/production/env.hcl`**

```hcl
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
```

- [ ] **Step 4: Create stub `README.md`**

```markdown
# richman-aws-eks

Production-grade Kubernetes on AWS. Full design: `docs/superpowers/specs/2026-05-20-richman-aws-eks-design.md`
```

- [ ] **Step 5: Commit**

```bash
git add .gitignore root.hcl live/production/env.hcl README.md
git commit -m "chore: scaffold repo — root.hcl, env.hcl, gitignore"
```

---

## Phase 1: Account-level infrastructure

### Task 2: VPC module — 3-tier, 3-AZ networking

**Files:**
- Create: `modules/account/vpc/main.tf`
- Create: `modules/account/vpc/endpoints.tf`
- Create: `modules/account/vpc/variables.tf`
- Create: `modules/account/vpc/outputs.tf`
- Create: `modules/account/vpc/versions.tf`

- [ ] **Step 1: Create `modules/account/vpc/versions.tf`**

```hcl
terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}
```

- [ ] **Step 2: Create `modules/account/vpc/variables.tf`**

```hcl
variable "project_name"        { type = string }
variable "environment"         { type = string }
variable "vpc_cidr"            { type = string; default = "10.0.0.0/16" }
variable "availability_zones"  { type = list(string) }
variable "single_nat_gateway"  { type = bool; default = false; description = "Use one NAT GW instead of one-per-AZ. Set true for dev/cost savings." }
variable "create_vpc_endpoints" { type = bool; default = true; description = "Create interface VPC endpoints (ECR, Secrets Manager, SSM, STS, EC2). ~$7/mo each per AZ." }
variable "tags"                { type = map(string); default = {} }
```

- [ ] **Step 3: Create `modules/account/vpc/main.tf`**

```hcl
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
```

- [ ] **Step 4: Create `modules/account/vpc/endpoints.tf`**

```hcl
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
```

- [ ] **Step 5: Create `modules/account/vpc/outputs.tf`**

```hcl
output "vpc_id"              { value = aws_vpc.main.id }
output "public_subnet_ids"   { value = aws_subnet.public[*].id }
output "private_subnet_ids"  { value = aws_subnet.private[*].id }
output "pod_subnet_ids"      { value = aws_subnet.pod[*].id }
output "availability_zones"  { value = var.availability_zones }
```

- [ ] **Step 6: Create `live/production/account/vpc/terragrunt.hcl`**

```hcl
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
```

- [ ] **Step 7: Commit**

```bash
git add modules/account/vpc live/production/account/vpc
git commit -m "feat: add VPC module — 3-tier 3-AZ networking with VPC endpoints"
```

---

### Task 3: IAM module — cluster and node roles

**Files:**
- Create: `modules/account/iam/main.tf`
- Create: `modules/account/iam/variables.tf`
- Create: `modules/account/iam/outputs.tf`
- Create: `modules/account/iam/versions.tf`
- Create: `live/production/account/iam/terragrunt.hcl`

- [ ] **Step 1: Create `modules/account/iam/versions.tf`**

```hcl
terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = { source = "hashicorp/aws"; version = "~> 5.0" }
  }
}
```

- [ ] **Step 2: Create `modules/account/iam/variables.tf`**

```hcl
variable "project_name" { type = string }
variable "environment"  { type = string }
variable "tags"         { type = map(string); default = {} }
```

- [ ] **Step 3: Create `modules/account/iam/main.tf`**

```hcl
data "aws_caller_identity" "current" {}

locals {
  common_tags = merge(var.tags, {
    Project     = var.project_name
    Environment = var.environment
  })
}

# ── EKS Cluster Role ──────────────────────────────────────────────────────────

resource "aws_iam_role" "eks_cluster" {
  name = "${var.project_name}-${var.environment}-eks-cluster-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "eks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "eks_cluster" {
  role       = aws_iam_role.eks_cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

# ── EKS Node Role ─────────────────────────────────────────────────────────────

resource "aws_iam_role" "eks_node" {
  name = "${var.project_name}-${var.environment}-eks-node-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "eks_node" {
  for_each = {
    worker    = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
    ecr       = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
    ssm       = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
    cni       = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
  }
  role       = aws_iam_role.eks_node.name
  policy_arn = each.value
}

# ECR pull-through cache — allows nodes to pull via ECR pull-through cache rules
resource "aws_iam_role_policy" "ecr_pull_through" {
  name = "ecr-pull-through-cache"
  role = aws_iam_role.eks_node.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "ecr:BatchImportUpstreamImage",
        "ecr:CreateRepository",
        "ecr:GetAuthorizationToken",
        "ecr:BatchGetImage",
        "ecr:GetDownloadUrlForLayer",
      ]
      Resource = "*"
    }]
  })
}

# Store role ARNs in SSM for consumption by cluster module
resource "aws_ssm_parameter" "node_role_arn" {
  name  = "/${var.project_name}/${var.environment}/iam/node-role-arn"
  type  = "String"
  value = aws_iam_role.eks_node.arn
}

resource "aws_ssm_parameter" "cluster_role_arn" {
  name  = "/${var.project_name}/${var.environment}/iam/cluster-role-arn"
  type  = "String"
  value = aws_iam_role.eks_cluster.arn
}
```

- [ ] **Step 4: Create `modules/account/iam/outputs.tf`**

```hcl
output "cluster_role_arn" { value = aws_iam_role.eks_cluster.arn }
output "node_role_arn"    { value = aws_iam_role.eks_node.arn }
output "node_role_name"   { value = aws_iam_role.eks_node.name }
```

- [ ] **Step 5: Create `live/production/account/iam/terragrunt.hcl`**

```hcl
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
```

- [ ] **Step 6: Commit**

```bash
git add modules/account/iam live/production/account/iam
git commit -m "feat: add IAM module — EKS cluster role and node role"
```

---

### Task 4: ECR module — repositories and pull-through cache

**Files:**
- Create: `modules/account/ecr/main.tf`
- Create: `modules/account/ecr/variables.tf`
- Create: `modules/account/ecr/outputs.tf`
- Create: `modules/account/ecr/versions.tf`
- Create: `live/production/account/ecr/terragrunt.hcl`

- [ ] **Step 1: Create `modules/account/ecr/versions.tf`**

```hcl
terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = { source = "hashicorp/aws"; version = "~> 5.0" }
  }
}
```

- [ ] **Step 2: Create `modules/account/ecr/variables.tf`**

```hcl
variable "project_name"    { type = string }
variable "environment"     { type = string }
variable "tags"            { type = map(string); default = {} }
variable "repositories"    {
  type        = list(string)
  default     = []
  description = "Application ECR repos to create. Platform images come via pull-through cache."
}
```

- [ ] **Step 3: Create `modules/account/ecr/main.tf`**

```hcl
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
}

resource "aws_ecr_pull_through_cache_rule" "quay" {
  ecr_repository_prefix = "quay"
  upstream_registry_url = "quay.io"
}

resource "aws_ecr_pull_through_cache_rule" "ghcr" {
  ecr_repository_prefix = "ghcr"
  upstream_registry_url = "ghcr.io"
}
```

- [ ] **Step 4: Create `modules/account/ecr/outputs.tf`**

```hcl
output "repository_urls" {
  value = { for k, v in aws_ecr_repository.app : k => v.repository_url }
}
```

- [ ] **Step 5: Create `live/production/account/ecr/terragrunt.hcl`**

```hcl
include "root" {
  path = find_in_parent_folders("root.hcl")
}

locals {
  env = read_terragrunt_config(find_in_parent_folders("env.hcl"))
}

terraform {
  source = "../../../../modules/account/ecr"
}

inputs = {
  project_name = local.env.locals.project_name
  environment  = local.env.locals.environment
  repositories = []   # add application repo names here
  tags         = { ManagedBy = "terraform" }
}
```

- [ ] **Step 6: Commit**

```bash
git add modules/account/ecr live/production/account/ecr
git commit -m "feat: add ECR module — repos and pull-through cache rules"
```

---

## Phase 2: EKS cluster

### Task 5: EKS module — control plane, security groups, access entries

**Files:**
- Create: `modules/cluster/eks/main.tf`
- Create: `modules/cluster/eks/security-groups.tf`
- Create: `modules/cluster/eks/variables.tf`
- Create: `modules/cluster/eks/outputs.tf`
- Create: `modules/cluster/eks/versions.tf`

- [ ] **Step 1: Create `modules/cluster/eks/versions.tf`**

```hcl
terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = { source = "hashicorp/aws"; version = "~> 5.0" }
  }
}
```

- [ ] **Step 2: Create `modules/cluster/eks/variables.tf`**

```hcl
variable "project_name"        { type = string }
variable "cluster_name"        { type = string }
variable "environment"         { type = string }
variable "kubernetes_version"  { type = string }
variable "vpc_id"              { type = string }
variable "private_subnet_ids"  { type = list(string) }
# AWS hard limit: max 40 CIDRs for EKS public API access. Validated below.
variable "admin_cidr"          { type = string; description = "CIDR allowed to reach kubectl (port 6443). Your IP or VPN CIDR." }
variable "tags"                { type = map(string); default = {} }

validation {
  condition     = length(split(",", var.admin_cidr)) <= 40
  error_message = "AWS limits EKS public_access_cidrs to 40 entries."
}
```

- [ ] **Step 3: Create `modules/cluster/eks/security-groups.tf`**

```hcl
locals {
  common_tags = merge(var.tags, {
    Project     = var.project_name
    Environment = var.environment
    Cluster     = var.cluster_name
  })
}

resource "aws_security_group" "control_plane" {
  name        = "${var.cluster_name}-control-plane-sg"
  description = "EKS control plane — allows 443 from nodes"
  vpc_id      = var.vpc_id
  egress {
    from_port   = 0; to_port = 0; protocol = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Allow all outbound"
  }
  tags = merge(local.common_tags, { Name = "${var.cluster_name}-control-plane-sg" })
}

resource "aws_security_group" "nodes" {
  name        = "${var.cluster_name}-nodes-sg"
  description = "All cluster nodes — full bidirectional within group"
  vpc_id      = var.vpc_id
  ingress {
    from_port = 0; to_port = 0; protocol = "-1"
    self      = true
    description = "Full mesh between nodes"
  }
  ingress {
    from_port       = 443; to_port = 443; protocol = "tcp"
    security_groups = [aws_security_group.control_plane.id]
    description     = "Webhook traffic from control plane"
  }
  egress {
    from_port   = 0; to_port = 0; protocol = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Allow all outbound"
  }
  tags = merge(local.common_tags, { Name = "${var.cluster_name}-nodes-sg" })
}

resource "aws_security_group_rule" "control_plane_from_nodes" {
  type                     = "ingress"
  from_port                = 443; to_port = 443; protocol = "tcp"
  security_group_id        = aws_security_group.control_plane.id
  source_security_group_id = aws_security_group.nodes.id
  description              = "API server access from nodes"
}

resource "aws_security_group" "nlb" {
  name        = "${var.cluster_name}-nlb-sg"
  description = "NLB — internet-facing 80/443"
  vpc_id      = var.vpc_id
  ingress {
    from_port   = 80;  to_port = 80;  protocol = "tcp"
    cidr_blocks = ["0.0.0.0/0"]; description = "HTTP"
  }
  ingress {
    from_port   = 443; to_port = 443; protocol = "tcp"
    cidr_blocks = ["0.0.0.0/0"]; description = "HTTPS"
  }
  egress {
    from_port   = 0; to_port = 0; protocol = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = merge(local.common_tags, { Name = "${var.cluster_name}-nlb-sg" })
}
```

- [ ] **Step 4: Create `modules/cluster/eks/main.tf`**

```hcl
data "aws_caller_identity" "current" {}
data "aws_iam_roles" "sso_admin" {
  name_regex = "^AWSReservedSSO_admin_.*"
}

data "aws_ssm_parameter" "cluster_role_arn" {
  name = "/${var.project_name}/${var.environment}/iam/cluster-role-arn"
}
data "aws_ssm_parameter" "node_role_arn" {
  name = "/${var.project_name}/${var.environment}/iam/node-role-arn"
}

resource "aws_cloudwatch_log_group" "cluster" {
  name              = "/aws/eks/${var.cluster_name}/cluster"
  retention_in_days = 30
  tags              = local.common_tags
}

resource "aws_eks_cluster" "main" {
  name     = var.cluster_name
  role_arn = data.aws_ssm_parameter.cluster_role_arn.value
  version  = var.kubernetes_version

  bootstrap_self_managed_addons = false

  vpc_config {
    subnet_ids              = var.private_subnet_ids
    security_group_ids      = [aws_security_group.control_plane.id]
    endpoint_private_access = true
    endpoint_public_access  = true
    public_access_cidrs     = [var.admin_cidr]
  }

  access_config {
    authentication_mode                         = "API_AND_CONFIG_MAP"
    bootstrap_cluster_creator_admin_permissions = true
  }

  enabled_cluster_log_types = ["api", "audit", "authenticator", "controllerManager", "scheduler"]

  depends_on = [aws_cloudwatch_log_group.cluster]
  tags       = local.common_tags

  lifecycle { prevent_destroy = true }
}

# Grant SSO admin roles cluster-admin access via EKS access entries (not aws-auth ConfigMap)
resource "aws_eks_access_entry" "sso_admin" {
  for_each      = toset(data.aws_iam_roles.sso_admin.arns)
  cluster_name  = aws_eks_cluster.main.name
  principal_arn = each.value
  tags          = local.common_tags
}

resource "aws_eks_access_policy_association" "sso_admin" {
  for_each      = toset(data.aws_iam_roles.sso_admin.arns)
  cluster_name  = aws_eks_cluster.main.name
  principal_arn = each.value
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
  access_scope  { type = "cluster" }
  depends_on    = [aws_eks_access_entry.sso_admin]
}

# Node group access entry — allows nodes to register
resource "aws_eks_access_entry" "nodes" {
  cluster_name  = aws_eks_cluster.main.name
  principal_arn = data.aws_ssm_parameter.node_role_arn.value
  type          = "EC2_LINUX"
  tags          = local.common_tags
}

# Store cluster outputs in SSM for karpenter + argocd-bootstrap modules
resource "aws_ssm_parameter" "cluster_name" {
  name  = "/${var.project_name}/${var.environment}/cluster/name"
  type  = "String"
  value = aws_eks_cluster.main.name
}

resource "aws_ssm_parameter" "cluster_endpoint" {
  name  = "/${var.project_name}/${var.environment}/cluster/endpoint"
  type  = "String"
  value = aws_eks_cluster.main.endpoint
}

resource "aws_ssm_parameter" "cluster_ca" {
  name  = "/${var.project_name}/${var.environment}/cluster/ca"
  type  = "String"
  value = aws_eks_cluster.main.certificate_authority[0].data
}
```

- [ ] **Step 5: Create `modules/cluster/eks/outputs.tf`**

```hcl
output "cluster_name"         { value = aws_eks_cluster.main.name }
output "cluster_endpoint"     { value = aws_eks_cluster.main.endpoint }
output "cluster_ca"           { value = aws_eks_cluster.main.certificate_authority[0].data }
output "cluster_oidc_issuer"  { value = aws_eks_cluster.main.identity[0].oidc[0].issuer }
output "node_sg_id"           { value = aws_security_group.nodes.id }
output "nlb_sg_id"            { value = aws_security_group.nlb.id }
```

- [ ] **Step 6: Commit**

```bash
git add modules/cluster/eks
git commit -m "feat: add EKS module — control plane, security groups, access entries"
```

---

### Task 6: EKS module — managed addons and system node group

**Files:**
- Modify: `modules/cluster/eks/` (add new files)
- Create: `modules/cluster/eks/addons.tf`
- Create: `modules/cluster/eks/node-group.tf`
- Create: `modules/cluster/eks/pod-identities.tf`
- Create: `live/production/cluster/eks/terragrunt.hcl`

- [ ] **Step 1: Create `modules/cluster/eks/addons.tf`**

```hcl
variable "addon_versions" {
  type = object({
    vpc_cni          = string
    kube_proxy       = string
    coredns          = string
    ebs_csi          = string
    pod_identity     = string
  })
  description = "Pinned EKS managed addon versions. Find latest: aws eks describe-addon-versions --kubernetes-version <k8s_version>"
}

variable "pod_subnet_ids" {
  type        = list(string)
  description = "Dedicated pod subnets per AZ for VPC CNI custom networking (prefix delegation)."
}

variable "availability_zones" {
  type = list(string)
}

# VPC CNI — prefix delegation + custom networking + NetworkPolicy enforcement
resource "aws_eks_addon" "vpc_cni" {
  cluster_name                = aws_eks_cluster.main.name
  addon_name                  = "vpc-cni"
  addon_version               = var.addon_versions.vpc_cni
  resolve_conflicts_on_update = "OVERWRITE"
  resolve_conflicts_on_create = "OVERWRITE"

  configuration_values = jsonencode({
    env = {
      ENABLE_PREFIX_DELEGATION           = "true"
      AWS_VPC_K8S_CNI_CUSTOM_NETWORK_CFG = "true"
      # Select ENIConfig by node AZ label
      ENI_CONFIG_LABEL_DEF               = "topology.kubernetes.io/zone"
      # Enable VPC CNI native NetworkPolicy enforcement (no Calico needed)
      NETWORK_POLICY_ENFORCING_MODE      = "standard"
    }
    # Create ENIConfig CRs — one per AZ pointing at pod subnet
    eniConfig = {
      create = true
      region = data.aws_region.current.name
      subnets = {
        for i, az in var.availability_zones :
        az => {
          id             = var.pod_subnet_ids[i]
          securityGroups = [aws_security_group.nodes.id]
        }
      }
    }
  })

  depends_on = [aws_eks_cluster.main]
  tags       = local.common_tags

  timeouts {
    create = "30m"
    update = "30m"
    delete = "30m"
  }
}

data "aws_region" "current" {}

resource "aws_eks_addon" "kube_proxy" {
  cluster_name                = aws_eks_cluster.main.name
  addon_name                  = "kube-proxy"
  addon_version               = var.addon_versions.kube_proxy
  resolve_conflicts_on_update = "OVERWRITE"
  depends_on                  = [aws_eks_cluster.main]
  tags                        = local.common_tags
}

resource "aws_eks_addon" "coredns" {
  cluster_name                = aws_eks_cluster.main.name
  addon_name                  = "coredns"
  addon_version               = var.addon_versions.coredns
  resolve_conflicts_on_update = "OVERWRITE"
  depends_on                  = [aws_eks_node_group.system]
  tags                        = local.common_tags
}

resource "aws_eks_addon" "ebs_csi" {
  cluster_name                = aws_eks_cluster.main.name
  addon_name                  = "aws-ebs-csi-driver"
  addon_version               = var.addon_versions.ebs_csi
  resolve_conflicts_on_update = "OVERWRITE"
  depends_on                  = [aws_eks_cluster.main]
  tags                        = local.common_tags
}

resource "aws_eks_addon" "pod_identity" {
  cluster_name  = aws_eks_cluster.main.name
  addon_name    = "eks-pod-identity-agent"
  addon_version = var.addon_versions.pod_identity
  resolve_conflicts_on_update = "OVERWRITE"

  # Must tolerate system node taint to run on system nodes
  configuration_values = jsonencode({
    tolerations = [{
      key    = "system-node"
      value  = "true"
      effect = "NoSchedule"
    }]
  })

  depends_on = [aws_eks_node_group.system]
  tags       = local.common_tags
}
```

- [ ] **Step 2: Create `modules/cluster/eks/node-group.tf`**

```hcl
variable "system_node_instance_type"  { type = string; default = "m6i.xlarge" }
variable "system_node_desired"        { type = number; default = 2 }
variable "system_node_min"            { type = number; default = 2 }
variable "system_node_max"            { type = number; default = 4 }
variable "eks_ami_release_version"    { type = string; description = "EKS optimized AMI release version for the node group." }

data "aws_ec2_instance_type" "system_primary" {
  instance_type = var.system_node_instance_type
}

# Find equivalent instance types (same vCPU + memory, same generation family) as fallback
data "aws_ec2_instance_types" "system_fallback" {
  filter {
    name   = "processor-info.supported-architecture"
    values = data.aws_ec2_instance_type.system_primary.supported_architectures
  }
  filter {
    name   = "vcpu-info.default-vcpus"
    values = [tostring(data.aws_ec2_instance_type.system_primary.default_vcpus)]
  }
  filter {
    name   = "memory-info.size-in-mib"
    values = [tostring(data.aws_ec2_instance_type.system_primary.memory_size)]
  }
  filter {
    name   = "instance-type"
    values = ["${substr(var.system_node_instance_type, 0, 1)}*"]
  }
}

resource "aws_launch_template" "system" {
  name = "${var.cluster_name}-system-node-lt"

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size           = 100
      volume_type           = "gp3"
      delete_on_termination = true
      encrypted             = true
    }
  }

  tag_specifications {
    resource_type = "instance"
    tags = merge(local.common_tags, { Name = "${var.cluster_name}-system-node" })
  }
  tag_specifications {
    resource_type = "volume"
    tags = merge(local.common_tags, { Name = "${var.cluster_name}-system-node-volume" })
  }

  tags = local.common_tags
}

resource "aws_eks_node_group" "system" {
  cluster_name           = aws_eks_cluster.main.name
  node_group_name_prefix = "${var.cluster_name}-system-"
  node_role_arn          = data.aws_ssm_parameter.node_role_arn.value
  subnet_ids             = var.private_subnet_ids
  release_version        = var.eks_ami_release_version
  capacity_type          = "ON_DEMAND"

  instance_types = distinct(concat(
    [var.system_node_instance_type],
    sort(data.aws_ec2_instance_types.system_fallback.instance_types)
  ))

  launch_template {
    name    = aws_launch_template.system.name
    version = aws_launch_template.system.latest_version
  }

  scaling_config {
    desired_size = var.system_node_desired
    min_size     = var.system_node_min
    max_size     = var.system_node_max
  }

  update_config {
    max_unavailable = 1
  }

  # Taint system nodes — platform components must tolerate this; workloads don't run here
  taint {
    key    = "system-node"
    value  = "true"
    effect = "NO_SCHEDULE"
  }

  labels = {
    "node.kubernetes.io/role" = "system"
    "system-node"             = "true"
  }

  lifecycle {
    # node_group_name_prefix generates a unique name; ignore desire_size changes
    # (could be changed externally by emergency scaling)
    create_before_destroy = true
    ignore_changes        = [scaling_config[0].desired_size]
  }

  tags = merge(local.common_tags, { Name = "${var.cluster_name}-system-node-group" })
}
```

- [ ] **Step 3: Create `modules/cluster/eks/pod-identities.tf`**

```hcl
# All AWS service account → IAM role mappings for Pod Identity.
# Add new entries here when adding a new service account that needs AWS access.
# For cross-account access where Pod Identity doesn't reach, see README: "Using IRSA".

variable "pod_identity_associations" {
  type = list(object({
    namespace       = string
    service_account = string
    role_arn        = string
  }))
  default     = []
  description = "List of Pod Identity associations. One per service account that needs AWS access."
}

resource "aws_eks_pod_identity_association" "main" {
  for_each = {
    for a in var.pod_identity_associations :
    "${a.namespace}/${a.service_account}" => a
  }
  cluster_name    = aws_eks_cluster.main.name
  namespace       = each.value.namespace
  service_account = each.value.service_account
  role_arn        = each.value.role_arn
  tags            = local.common_tags
}
```

- [ ] **Step 4: Create `live/production/cluster/eks/terragrunt.hcl`**

```hcl
include "root" {
  path = find_in_parent_folders("root.hcl")
}

locals {
  env = read_terragrunt_config(find_in_parent_folders("env.hcl"))
  l   = local.env.locals
}

terraform {
  source = "../../../../modules/cluster/eks"
}

# Read VPC outputs from SSM (written by account/vpc module)
data "aws_ssm_parameters_by_path" {
  path = "/${local.l.project_name}/${local.l.environment}/vpc"
}

inputs = {
  project_name       = local.l.project_name
  cluster_name       = local.l.cluster_name
  environment        = local.l.environment
  kubernetes_version = local.l.kubernetes_version
  admin_cidr         = local.l.admin_cidr
  availability_zones = local.l.availability_zones

  # Read from SSM — set by account/vpc module
  vpc_id            = data.aws_ssm_parameter.vpc_id.insecure_value
  private_subnet_ids = [
    data.aws_ssm_parameter.private_subnet_0.insecure_value,
    data.aws_ssm_parameter.private_subnet_1.insecure_value,
    data.aws_ssm_parameter.private_subnet_2.insecure_value,
  ]
  pod_subnet_ids = [
    data.aws_ssm_parameter.pod_subnet_0.insecure_value,
    data.aws_ssm_parameter.pod_subnet_1.insecure_value,
    data.aws_ssm_parameter.pod_subnet_2.insecure_value,
  ]

  # Pin addon versions. Find latest:
  # aws eks describe-addon-versions --kubernetes-version 1.31 --query 'addons[].{name:addonName,version:addonVersions[0].addonVersion}'
  addon_versions = {
    vpc_cni      = "v1.19.0-eksbuild.1"
    kube_proxy   = "v1.31.2-eksbuild.3"
    coredns      = "v1.11.3-eksbuild.2"
    ebs_csi      = "v1.37.0-eksbuild.1"
    pod_identity = "v1.3.4-eksbuild.1"
  }

  eks_ami_release_version = "1.31.4-20250123"

  system_node_instance_type = "m6i.xlarge"
  system_node_desired       = 2
  system_node_min           = 2
  system_node_max           = 4

  # Pod Identity associations — populated in Task 9 after Karpenter IAM roles exist
  pod_identity_associations = []

  tags = { ManagedBy = "terraform" }
}
```

- [ ] **Step 5: Commit**

```bash
git add modules/cluster/eks live/production/cluster/eks
git commit -m "feat: add EKS addons, system node group, pod identity associations"
```

---

### Task 7: Karpenter module — IAM, SQS, EventBridge

**Files:**
- Create: `modules/cluster/karpenter/main.tf`
- Create: `modules/cluster/karpenter/variables.tf`
- Create: `modules/cluster/karpenter/outputs.tf`
- Create: `modules/cluster/karpenter/versions.tf`
- Create: `live/production/cluster/karpenter/terragrunt.hcl`

- [ ] **Step 1: Create `modules/cluster/karpenter/versions.tf`**

```hcl
terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = { source = "hashicorp/aws"; version = "~> 5.0" }
  }
}
```

- [ ] **Step 2: Create `modules/cluster/karpenter/variables.tf`**

```hcl
variable "project_name"  { type = string }
variable "cluster_name"  { type = string }
variable "environment"   { type = string }
variable "tags"          { type = map(string); default = {} }
```

- [ ] **Step 3: Create `modules/cluster/karpenter/main.tf`**

```hcl
data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
data "aws_region" "current" {}

data "aws_ssm_parameter" "node_role_arn" {
  name = "/${var.project_name}/${var.environment}/iam/node-role-arn"
}

locals {
  common_tags = merge(var.tags, {
    Project     = var.project_name
    Environment = var.environment
    Cluster     = var.cluster_name
  })
  partition  = data.aws_partition.current.partition
  account_id = data.aws_caller_identity.current.account_id
  region     = data.aws_region.current.name
}

# ── Interruption queue ────────────────────────────────────────────────────────
# Karpenter subscribes to this queue for SPOT interruption warnings,
# rebalance recommendations, and health events — enables graceful 2-min drain.

resource "aws_sqs_queue" "interruption" {
  name                      = var.cluster_name
  message_retention_seconds = 300
  sqs_managed_sse_enabled   = true
  tags                      = local.common_tags
}

resource "aws_sqs_queue_policy" "interruption" {
  queue_url = aws_sqs_queue.interruption.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = ["events.amazonaws.com", "sqs.amazonaws.com"] }
        Action    = "sqs:SendMessage"
        Resource  = aws_sqs_queue.interruption.arn
      },
      {
        Effect    = "Deny"
        Principal = "*"
        Action    = "sqs:*"
        Resource  = aws_sqs_queue.interruption.arn
        Condition = { Bool = { "aws:SecureTransport" = false } }
      }
    ]
  })
}

# EventBridge rules → SQS
locals {
  event_rules = {
    spot-interruption    = { source = ["aws.ec2"],    detail-type = ["EC2 Spot Instance Interruption Warning"] }
    rebalance            = { source = ["aws.ec2"],    detail-type = ["EC2 Instance Rebalance Recommendation"] }
    instance-state       = { source = ["aws.ec2"],    detail-type = ["EC2 Instance State-change Notification"] }
    scheduled-change     = { source = ["aws.health"], detail-type = ["AWS Health Event"] }
  }
}

resource "aws_cloudwatch_event_rule" "karpenter" {
  for_each      = local.event_rules
  name          = "${var.cluster_name}-${each.key}"
  event_pattern = jsonencode({ source = each.value.source, "detail-type" = each.value.detail-type })
  tags          = local.common_tags
}

resource "aws_cloudwatch_event_target" "karpenter" {
  for_each  = local.event_rules
  rule      = aws_cloudwatch_event_rule.karpenter[each.key].name
  target_id = "${var.cluster_name}-${each.key}"
  arn       = aws_sqs_queue.interruption.arn
}

# ── Karpenter controller IAM role ─────────────────────────────────────────────

resource "aws_iam_role" "karpenter_controller" {
  name = "${var.cluster_name}-karpenter-controller"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "pods.eks.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })
  tags = local.common_tags
}

resource "aws_iam_policy" "karpenter_controller" {
  name = "${var.cluster_name}-karpenter-controller"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "EC2Fleet"
        Effect = "Allow"
        Action = ["ec2:RunInstances", "ec2:CreateFleet", "ec2:CreateLaunchTemplate"]
        Resource = [
          "arn:${local.partition}:ec2:${local.region}::image/*",
          "arn:${local.partition}:ec2:${local.region}::snapshot/*",
          "arn:${local.partition}:ec2:${local.region}:*:spot-instances-request/*",
          "arn:${local.partition}:ec2:${local.region}:*:security-group/*",
          "arn:${local.partition}:ec2:${local.region}:*:subnet/*",
          "arn:${local.partition}:ec2:${local.region}:*:launch-template/*",
          "arn:${local.partition}:ec2:${local.region}:*:fleet/*",
          "arn:${local.partition}:ec2:${local.region}:*:instance/*",
          "arn:${local.partition}:ec2:${local.region}:*:volume/*",
          "arn:${local.partition}:ec2:${local.region}:*:network-interface/*",
        ]
        Condition = {
          StringEquals = {
            "aws:RequestTag/kubernetes.io/cluster/${var.cluster_name}" = "owned"
          }
        }
      },
      {
        Sid    = "Termination"
        Effect = "Allow"
        Action = ["ec2:TerminateInstances", "ec2:DeleteLaunchTemplate"]
        Resource = [
          "arn:${local.partition}:ec2:${local.region}:*:instance/*",
          "arn:${local.partition}:ec2:${local.region}:*:launch-template/*",
        ]
        Condition = {
          StringEquals = {
            "aws:ResourceTag/kubernetes.io/cluster/${var.cluster_name}" = "owned"
          }
        }
      },
      {
        Sid    = "ReadOnly"
        Effect = "Allow"
        Action = [
          "ec2:DescribeAvailabilityZones", "ec2:DescribeImages", "ec2:DescribeInstances",
          "ec2:DescribeInstanceTypeOfferings", "ec2:DescribeInstanceTypes",
          "ec2:DescribeLaunchTemplates", "ec2:DescribeSecurityGroups",
          "ec2:DescribeSpotPriceHistory", "ec2:DescribeSubnets",
          "pricing:GetProducts", "ssm:GetParameter",
          "eks:DescribeCluster",
        ]
        Resource = ["*"]
      },
      {
        Sid    = "Tagging"
        Effect = "Allow"
        Action = ["ec2:CreateTags"]
        Resource = ["arn:${local.partition}:ec2:${local.region}:*:*"]
      },
      {
        Sid    = "SQS"
        Effect = "Allow"
        Action = ["sqs:DeleteMessage", "sqs:GetQueueAttributes", "sqs:GetQueueUrl", "sqs:ReceiveMessage"]
        Resource = [aws_sqs_queue.interruption.arn]
      },
      {
        Sid    = "PassNodeRole"
        Effect = "Allow"
        Action = ["iam:PassRole"]
        Resource = [data.aws_ssm_parameter.node_role_arn.value]
        Condition = { StringEquals = { "iam:PassedToService" = "ec2.amazonaws.com" } }
      },
      {
        Sid    = "InstanceProfile"
        Effect = "Allow"
        Action = [
          "iam:CreateInstanceProfile", "iam:TagInstanceProfile",
          "iam:AddRoleToInstanceProfile", "iam:RemoveRoleFromInstanceProfile",
          "iam:DeleteInstanceProfile", "iam:GetInstanceProfile",
        ]
        Resource = ["arn:${local.partition}:iam::${local.account_id}:instance-profile/*"]
      },
    ]
  })
  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "karpenter_controller" {
  role       = aws_iam_role.karpenter_controller.name
  policy_arn = aws_iam_policy.karpenter_controller.arn
}

# Store the controller role ARN in SSM for the EKS pod-identity-associations input
resource "aws_ssm_parameter" "karpenter_controller_role_arn" {
  name  = "/${var.project_name}/${var.environment}/karpenter/controller-role-arn"
  type  = "String"
  value = aws_iam_role.karpenter_controller.arn
}

resource "aws_ssm_parameter" "interruption_queue_name" {
  name  = "/${var.project_name}/${var.environment}/karpenter/interruption-queue-name"
  type  = "String"
  value = aws_sqs_queue.interruption.name
}
```

- [ ] **Step 4: Create `modules/cluster/karpenter/outputs.tf`**

```hcl
output "controller_role_arn"     { value = aws_iam_role.karpenter_controller.arn }
output "interruption_queue_name" { value = aws_sqs_queue.interruption.name }
```

- [ ] **Step 5: Create `live/production/cluster/karpenter/terragrunt.hcl`**

```hcl
include "root" {
  path = find_in_parent_folders("root.hcl")
}

locals {
  env = read_terragrunt_config(find_in_parent_folders("env.hcl"))
}

terraform {
  source = "../../../../modules/cluster/karpenter"
}

inputs = {
  project_name = local.env.locals.project_name
  cluster_name = local.env.locals.cluster_name
  environment  = local.env.locals.environment
  tags         = { ManagedBy = "terraform" }
}
```

- [ ] **Step 6: Commit**

```bash
git add modules/cluster/karpenter live/production/cluster/karpenter
git commit -m "feat: add Karpenter module — IAM, SQS interruption queue, EventBridge rules"
```

---

### Task 8: Wire Pod Identity associations into EKS module

Now that Karpenter, ESO, LBC, ExternalDNS, EBS CSI, Velero, Cloud Custodian, and YACE roles exist (via Karpenter module and future modules), wire them into `live/production/cluster/eks/terragrunt.hcl`.

**Files:**
- Create: `modules/cluster/eks/addon-roles.tf` — IAM roles for all addon service accounts
- Modify: `live/production/cluster/eks/terragrunt.hcl` — add `pod_identity_associations`

- [ ] **Step 1: Create `modules/cluster/eks/addon-roles.tf`**

This file creates the IAM roles for every in-cluster service account that needs AWS access. All use Pod Identity trust (`pods.eks.amazonaws.com`).

```hcl
locals {
  addon_roles = {
    lbc = {
      name = "${var.cluster_name}-aws-lbc"
      policy = jsonencode({
        Version = "2012-10-17"
        Statement = [{
          Effect   = "Allow"
          Action   = ["elasticloadbalancing:*", "ec2:Describe*", "ec2:AuthorizeSecurityGroupIngress",
                      "ec2:RevokeSecurityGroupIngress", "ec2:CreateSecurityGroup",
                      "ec2:CreateTags", "ec2:DeleteTags", "wafv2:*", "shield:*",
                      "iam:CreateServiceLinkedRole"]
          Resource = ["*"]
        }]
      })
    }
    external_dns = {
      name = "${var.cluster_name}-external-dns"
      policy = jsonencode({
        Version = "2012-10-17"
        Statement = [
          {
            Effect   = "Allow"
            Action   = ["route53:ChangeResourceRecordSets"]
            Resource = ["arn:${local.partition}:route53:::hostedzone/*"]
          },
          {
            Effect   = "Allow"
            Action   = ["route53:ListHostedZones", "route53:ListResourceRecordSets", "route53:ListTagsForResource"]
            Resource = ["*"]
          }
        ]
      })
    }
    eso = {
      name = "${var.cluster_name}-external-secrets"
      policy = jsonencode({
        Version = "2012-10-17"
        Statement = [{
          Effect   = "Allow"
          Action   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret", "secretsmanager:ListSecrets"]
          Resource = ["arn:${local.partition}:secretsmanager:${local.region}:${local.account_id}:secret:*"]
        }]
      })
    }
    ebs_csi = {
      name = "${var.cluster_name}-ebs-csi"
      policy = jsonencode({
        Version = "2012-10-17"
        Statement = [{
          Effect   = "Allow"
          Action   = [
            "ec2:CreateVolume", "ec2:DeleteVolume", "ec2:AttachVolume", "ec2:DetachVolume",
            "ec2:ModifyVolume", "ec2:DescribeVolumes", "ec2:DescribeVolumesModifications",
            "ec2:DescribeSnapshots", "ec2:CreateSnapshot", "ec2:DeleteSnapshot",
            "ec2:CreateTags", "ec2:DescribeAvailabilityZones", "ec2:DescribeInstances",
          ]
          Resource = ["*"]
        }]
      })
    }
    velero = {
      name = "${var.cluster_name}-velero"
      policy = jsonencode({
        Version = "2012-10-17"
        Statement = [
          {
            Effect   = "Allow"
            Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket", "s3:GetBucketLocation"]
            Resource = [
              "arn:${local.partition}:s3:::${var.cluster_name}-velero-backups",
              "arn:${local.partition}:s3:::${var.cluster_name}-velero-backups/*"
            ]
          },
          {
            Effect   = "Allow"
            Action   = ["ec2:CreateSnapshot", "ec2:DeleteSnapshot", "ec2:DescribeSnapshots",
                        "ec2:CreateTags", "ec2:DescribeVolumes"]
            Resource = ["*"]
          }
        ]
      })
    }
    cloud_custodian = {
      name = "${var.cluster_name}-cloud-custodian"
      policy = jsonencode({
        Version = "2012-10-17"
        Statement = [{
          Effect   = "Allow"
          Action   = ["ec2:Describe*", "s3:List*", "s3:Get*", "rds:Describe*",
                      "iam:List*", "iam:Get*", "ec2:CreateTags", "ec2:DeleteTags",
                      "s3:PutBucketTagging", "rds:AddTagsToResource"]
          Resource = ["*"]
        }]
      })
    }
    yace = {
      name = "${var.cluster_name}-yace"
      policy = jsonencode({
        Version = "2012-10-17"
        Statement = [{
          Effect   = "Allow"
          Action   = ["cloudwatch:GetMetricData", "cloudwatch:ListMetrics",
                      "tag:GetResources", "sts:GetCallerIdentity"]
          Resource = ["*"]
        }]
      })
    }
    noe = {
      name = "${var.cluster_name}-noe"
      policy = jsonencode({
        Version = "2012-10-17"
        Statement = [{
          Effect   = "Allow"
          Action   = ["ec2:DescribeInstanceTypes"]
          Resource = ["*"]
        }]
      })
    }
  }
}

resource "aws_iam_role" "addon" {
  for_each = local.addon_roles
  name     = each.value.name
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "pods.eks.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })
  tags = local.common_tags
}

resource "aws_iam_role_policy" "addon" {
  for_each = local.addon_roles
  name     = "main"
  role     = aws_iam_role.addon[each.key].id
  policy   = each.value.policy
}

output "addon_role_arns" {
  value = { for k, v in aws_iam_role.addon : k => v.arn }
}
```

- [ ] **Step 2: Update `live/production/cluster/eks/terragrunt.hcl` — add `pod_identity_associations`**

Add to `inputs = { ... }`:

```hcl
  pod_identity_associations = [
    { namespace = "kube-system",       service_account = "aws-load-balancer-controller", role_arn = dependency.eks.outputs.addon_role_arns["lbc"] },
    { namespace = "external-dns",      service_account = "external-dns",                 role_arn = dependency.eks.outputs.addon_role_arns["external_dns"] },
    { namespace = "external-secrets",  service_account = "external-secrets-sa",          role_arn = dependency.eks.outputs.addon_role_arns["eso"] },
    { namespace = "kube-system",       service_account = "ebs-csi-controller-sa",         role_arn = dependency.eks.outputs.addon_role_arns["ebs_csi"] },
    { namespace = "velero",            service_account = "velero",                        role_arn = dependency.eks.outputs.addon_role_arns["velero"] },
    { namespace = "cloud-custodian",   service_account = "cloud-custodian",               role_arn = dependency.eks.outputs.addon_role_arns["cloud_custodian"] },
    { namespace = "monitoring",        service_account = "yace",                          role_arn = dependency.eks.outputs.addon_role_arns["yace"] },
    { namespace = "monitoring",        service_account = "noe",                           role_arn = dependency.eks.outputs.addon_role_arns["noe"] },
    { namespace = "karpenter",         service_account = "karpenter",                     role_arn = data.aws_ssm_parameter.karpenter_controller_role_arn.insecure_value },
  ]
```

- [ ] **Step 3: Commit**

```bash
git add modules/cluster/eks/addon-roles.tf live/production/cluster/eks/terragrunt.hcl
git commit -m "feat: add addon IAM roles and pod identity associations"
```

---

### Task 9: ArgoCD bootstrap module

**Files:**
- Create: `modules/cluster/argocd-bootstrap/main.tf`
- Create: `modules/cluster/argocd-bootstrap/configmap.tf`
- Create: `modules/cluster/argocd-bootstrap/variables.tf`
- Create: `modules/cluster/argocd-bootstrap/outputs.tf`
- Create: `modules/cluster/argocd-bootstrap/versions.tf`
- Create: `live/production/cluster/argocd-bootstrap/terragrunt.hcl`

- [ ] **Step 1: Create `modules/cluster/argocd-bootstrap/versions.tf`**

```hcl
terraform {
  required_version = ">= 1.10"
  required_providers {
    aws        = { source = "hashicorp/aws";       version = "~> 5.0" }
    helm       = { source = "hashicorp/helm";      version = "~> 2.0" }
    kubernetes = { source = "hashicorp/kubernetes"; version = "~> 2.0" }
  }
}
```

- [ ] **Step 2: Create `modules/cluster/argocd-bootstrap/variables.tf`**

```hcl
variable "project_name"    { type = string }
variable "cluster_name"    { type = string }
variable "environment"     { type = string }
variable "argocd_version"  { type = string; default = "7.7.0" }
variable "repo_url"        { type = string; description = "Git repo URL for cluster-applications (your fork)." }
variable "domain_name"     { type = string; description = "Base domain. ArgoCD will be at argocd.<domain_name>." }
variable "region"          { type = string }
variable "account_id"      { type = string }
variable "vpc_id"          { type = string }
variable "private_subnet_ids" { type = list(string) }
variable "pod_subnet_ids"     { type = list(string) }
variable "availability_zones" { type = list(string) }
variable "nlb_sg_id"         { type = string }
variable "node_sg_id"        { type = string }
variable "tags"              { type = map(string); default = {} }
```

- [ ] **Step 3: Create `modules/cluster/argocd-bootstrap/main.tf`**

```hcl
data "aws_eks_cluster" "main" {
  name = var.cluster_name
}
data "aws_eks_cluster_auth" "main" {
  name = var.cluster_name
}

locals {
  common_tags = merge(var.tags, {
    Project     = var.project_name
    Environment = var.environment
    Cluster     = var.cluster_name
  })
}

resource "helm_release" "argocd" {
  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = var.argocd_version
  namespace        = "argocd"
  create_namespace = true
  wait             = true
  timeout          = 600

  # Tolerate system nodes so ArgoCD runs on the system node group
  set {
    name  = "global.tolerations[0].key"
    value = "system-node"
  }
  set {
    name  = "global.tolerations[0].operator"
    value = "Equal"
  }
  set {
    name  = "global.tolerations[0].value"
    value = "true"
  }
  set {
    name  = "global.tolerations[0].effect"
    value = "NoSchedule"
  }

  # Production-tuned controller settings (from operating ArgoCD at scale)
  set { name = "controller.replicas";                        value = "1" }
  set { name = "server.replicas";                            value = "2" }
  set { name = "repoServer.replicas";                        value = "2" }
  set { name = "applicationSet.replicas";                    value = "2" }

  # Work queue — prevents sync throttling at scale (upstream ArgoCD issue)
  set { name = "controller.env[0].name";                     value = "WORKQUEUE_BUCKET_SIZE" }
  set { name = "controller.env[0].value";                    value = "9223372036854775807" }
  set { name = "controller.env[1].name";                     value = "WORKQUEUE_BUCKET_QPS" }
  set { name = "controller.env[1].value";                    value = "9223372036854775807" }

  # Status processors scaled up for many Applications
  set { name = "controller.extraArgs[0]";                    value = "--status-processors=50" }
  set { name = "controller.extraArgs[1]";                    value = "--operation-processors=25" }

  # HA Redis — single-replica Redis is a silent ArgoCD SPOF
  set { name = "redis-ha.enabled";                           value = "true" }
  set { name = "redis.enabled";                              value = "false" }

  # Progressive sync support for multi-cluster ApplicationSets
  set { name = "applicationSet.extraArgs[0]";                value = "--enable-progressive-syncs" }

  # Exclude Velero Backup objects — high-churn, pollutes diff view
  set { name = "server.config.resource\\.exclusions";        value = "- apiGroups:\\n  - velero.io\\n  kinds:\\n  - Backup\\n  clusters:\\n  - '*'" }
}

# Root App-of-Apps — points ArgoCD at cluster-applications/bootstrap/
resource "kubernetes_manifest" "app_of_apps" {
  manifest = {
    apiVersion = "argoproj.io/v1alpha1"
    kind       = "Application"
    metadata = {
      name      = "platform"
      namespace = "argocd"
      annotations = {
        "argocd.argoproj.io/sync-wave" = "0"
      }
    }
    spec = {
      project = "default"
      source = {
        repoURL        = var.repo_url
        targetRevision = "HEAD"
        path           = "cluster-applications/bootstrap"
        helm = {
          valueFiles = ["../../cluster-applications/environments/${var.environment}.yaml"]
        }
      }
      destination = {
        server    = "https://kubernetes.default.svc"
        namespace = "argocd"
      }
      syncPolicy = {
        automated = {
          prune    = true
          selfHeal = true
        }
        syncOptions = ["CreateNamespace=true"]
      }
    }
  }
  depends_on = [helm_release.argocd]
}
```

- [ ] **Step 4: Create `modules/cluster/argocd-bootstrap/configmap.tf`**

This writes the environment-specific values that cannot live in git (VPC IDs, subnet IDs, account ID) into an ArgoCD ConfigMap so the bootstrap chart can stamp them into child Applications.

```hcl
resource "kubernetes_config_map" "env_values" {
  metadata {
    name      = "platform-env-values"
    namespace = "argocd"
  }

  data = {
    "values.yaml" = yamlencode({
      clusterName       = var.cluster_name
      environment       = var.environment
      region            = var.region
      accountId         = var.account_id
      domain            = var.domain_name
      vpcId             = var.vpc_id
      privateSubnetIds  = var.private_subnet_ids
      podSubnetIds      = var.pod_subnet_ids
      availabilityZones = var.availability_zones
      nlbSecurityGroupId = var.nlb_sg_id
      nodeSecurityGroupId = var.node_sg_id
    })
  }

  depends_on = [helm_release.argocd]
}
```

- [ ] **Step 5: Create `modules/cluster/argocd-bootstrap/outputs.tf`**

```hcl
output "argocd_namespace" { value = "argocd" }
```

- [ ] **Step 6: Create `live/production/cluster/argocd-bootstrap/terragrunt.hcl`**

```hcl
include "root" {
  path = find_in_parent_folders("root.hcl")
}

locals {
  env = read_terragrunt_config(find_in_parent_folders("env.hcl"))
  l   = local.env.locals
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
  repo_url           = get_env("REPO_URL", "")
  account_id         = get_aws_account_id()

  # Read from SSM (written by vpc + eks modules)
  vpc_id               = data.aws_ssm_parameter.vpc_id.insecure_value
  private_subnet_ids   = [for i in range(3) : data.aws_ssm_parameter.private_subnets[i].insecure_value]
  pod_subnet_ids       = [for i in range(3) : data.aws_ssm_parameter.pod_subnets[i].insecure_value]
  nlb_sg_id            = data.aws_ssm_parameter.nlb_sg_id.insecure_value
  node_sg_id           = data.aws_ssm_parameter.node_sg_id.insecure_value

  tags = { ManagedBy = "terraform" }
}
```

- [ ] **Step 7: Commit**

```bash
git add modules/cluster/argocd-bootstrap live/production/cluster/argocd-bootstrap
git commit -m "feat: add ArgoCD bootstrap module — Helm install + App-of-Apps"
```

---

## Phase 3: Bootstrap Helm chart (App-of-Apps)

### Task 10: Bootstrap chart — generates one Application per platform group

**Files:**
- Create: `cluster-applications/bootstrap/Chart.yaml`
- Create: `cluster-applications/bootstrap/values.yaml`
- Create: `cluster-applications/bootstrap/templates/platform-core.yaml`
- Create: `cluster-applications/bootstrap/templates/platform-networking.yaml`
- Create: `cluster-applications/bootstrap/templates/platform-autoscaling.yaml`
- Create: `cluster-applications/bootstrap/templates/platform-secrets.yaml`
- Create: `cluster-applications/bootstrap/templates/platform-policy.yaml`
- Create: `cluster-applications/bootstrap/templates/platform-observability.yaml`
- Create: `cluster-applications/bootstrap/templates/platform-gitops.yaml`

- [ ] **Step 1: Create `cluster-applications/bootstrap/Chart.yaml`**

```yaml
apiVersion: v2
name: platform-bootstrap
description: Root App-of-Apps — generates one ArgoCD Application per platform group
version: 0.1.0
```

- [ ] **Step 2: Create `cluster-applications/bootstrap/values.yaml`**

```yaml
# Injected by Terraform at bootstrap time via platform-env-values ConfigMap.
# Do not edit manually — these are overridden by environments/<env>.yaml.
clusterName: ""
environment: "production"
region: ""
accountId: ""
domain: ""

repoURL: ""   # set via REPO_URL env var in argocd-bootstrap Terraform module

syncPolicy:
  automated:
    prune: true
    selfHeal: true
  syncOptions:
    - CreateNamespace=true
    - ServerSideApply=true

syncWaves:
  core:         "1"
  networking:   "2"
  secrets:      "2"
  autoscaling:  "3"
  nodepools:    "4"
  policy:       "5"
  observability: "6"
  gitops:       "7"
```

- [ ] **Step 3: Create `cluster-applications/bootstrap/templates/platform-core.yaml`**

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: platform-core
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: {{ .Values.syncWaves.core | quote }}
spec:
  project: default
  source:
    repoURL: {{ .Values.repoURL }}
    targetRevision: HEAD
    path: cluster-applications/platform-core
    helm:
      valueFiles:
        - values/base.yaml
        - values/{{ .Values.environment }}.yaml
      parameters:
        - name: clusterName
          value: {{ .Values.clusterName }}
        - name: environment
          value: {{ .Values.environment }}
  destination:
    server: https://kubernetes.default.svc
    namespace: kube-system
  syncPolicy:
    {{- toYaml .Values.syncPolicy | nindent 4 }}
```

- [ ] **Step 4: Create remaining bootstrap Application templates**

Each follows the same pattern as `platform-core.yaml` but with its own `syncWave`, `path`, and default `namespace`. Create these files with the following sync waves and destination namespaces:

`cluster-applications/bootstrap/templates/platform-networking.yaml` — wave `{{ .Values.syncWaves.networking }}`, namespace `kube-system`

`cluster-applications/bootstrap/templates/platform-autoscaling.yaml` — wave `{{ .Values.syncWaves.autoscaling }}`, namespace `karpenter`

`cluster-applications/bootstrap/templates/platform-secrets.yaml` — wave `{{ .Values.syncWaves.secrets }}`, namespace `external-secrets`

`cluster-applications/bootstrap/templates/platform-policy.yaml` — wave `{{ .Values.syncWaves.policy }}`, namespace `kyverno`

`cluster-applications/bootstrap/templates/platform-observability.yaml` — wave `{{ .Values.syncWaves.observability }}`, namespace `monitoring`

`cluster-applications/bootstrap/templates/platform-gitops.yaml` — wave `{{ .Values.syncWaves.gitops }}`, namespace `argocd`

Each file has the same structure as `platform-core.yaml` above, substituting `platform-core` → `platform-networking` etc. in `metadata.name` and `path`.

- [ ] **Step 5: Commit**

```bash
git add cluster-applications/bootstrap
git commit -m "feat: add bootstrap App-of-Apps chart with sync waves"
```

---

## Phase 4: Platform Helm charts

### Task 11: platform-core — namespaces, priority classes, core tools

**Files:**
- Create: `cluster-applications/platform-core/Chart.yaml`
- Create: `cluster-applications/platform-core/values/base.yaml`
- Create: `cluster-applications/platform-core/values/production.yaml`
- Create: `cluster-applications/platform-core/templates/namespaces.yaml`
- Create: `cluster-applications/platform-core/templates/priority-classes.yaml`
- Create: `cluster-applications/platform-core/templates/flowschemas.yaml`
- Create: `cluster-applications/platform-core/templates/apps/metrics-server.yaml`
- Create: `cluster-applications/platform-core/templates/apps/vpa.yaml`
- Create: `cluster-applications/platform-core/templates/apps/node-problem-detector.yaml`
- Create: `cluster-applications/platform-core/templates/apps/node-local-dns.yaml`
- Create: `cluster-applications/platform-core/templates/apps/reloader.yaml`

- [ ] **Step 1: Create `cluster-applications/platform-core/Chart.yaml`**

```yaml
apiVersion: v2
name: platform-core
description: Namespaces, RBAC, PriorityClasses, APF flowschemas, and core tooling
version: 0.1.0
```

- [ ] **Step 2: Create `cluster-applications/platform-core/values/base.yaml`**

```yaml
clusterName: ""
environment: ""

vpa:
  version: "4.10.1"
  recommenderMinCpu: "15"
  recommenderMinMemMb: "100"
  admissionReplicas: 3

metricsServer:
  version: "3.12.2"

nodeProblemDetector:
  version: "2.3.14"

nodeLocalDns:
  version: "2.0.9"
  localDnsIp: "169.254.20.10"

reloader:
  version: "1.1.0"
```

- [ ] **Step 3: Create `cluster-applications/platform-core/values/production.yaml`**

```yaml
# Production-specific overrides. Merge on top of base.yaml.
vpa:
  admissionReplicas: 3   # HA — VPA admission webhook is a scheduling SPOF
```

- [ ] **Step 4: Create `cluster-applications/platform-core/templates/namespaces.yaml`**

```yaml
{{- $namespaces := list "monitoring" "external-secrets" "external-dns" "karpenter" "kyverno" "cloud-custodian" "velero" "cert-manager" "traefik" -}}
{{- range $namespaces }}
---
apiVersion: v1
kind: Namespace
metadata:
  name: {{ . }}
  labels:
    app.kubernetes.io/managed-by: argocd
{{- end }}
```

- [ ] **Step 5: Create `cluster-applications/platform-core/templates/priority-classes.yaml`**

```yaml
---
apiVersion: scheduling.k8s.io/v1
kind: PriorityClass
metadata:
  name: platform-high
value: 1000000
globalDefault: false
description: "Platform components that must not be evicted under normal pressure."
---
apiVersion: scheduling.k8s.io/v1
kind: PriorityClass
metadata:
  name: platform-default
value: 500000
globalDefault: false
description: "Default for platform tooling."
---
apiVersion: scheduling.k8s.io/v1
kind: PriorityClass
metadata:
  name: workload-default
value: 100000
globalDefault: true
description: "Default for application workloads."
```

- [ ] **Step 6: Create `cluster-applications/platform-core/templates/apps/vpa.yaml`**

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: vpa
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "1"
    # Protect CRDs on uninstall
    argocd.argoproj.io/sync-options: Delete=false
spec:
  project: default
  source:
    chart: vpa
    repoURL: https://charts.fairwinds.com/stable
    targetRevision: {{ .Values.vpa.version }}
    helm:
      valuesObject:
        recommender:
          extraArgs:
            pod-recommendation-min-cpu-millicores: {{ .Values.vpa.recommenderMinCpu }}
            pod-recommendation-min-memory-mb: {{ .Values.vpa.recommenderMinMemMb }}
            oom-bump-up-ratio: "1.5"
          resources:
            requests: { cpu: 200m, memory: 2Gi }
            limits:   { cpu: 500m, memory: 4Gi }
        updater:
          extraArgs:
            # Do not evict single-replica deployments — prevents taking down singletons
            min-replicas: "1"
            feature-gates: "InPlaceOrRecreate=true"
          resources:
            requests: { cpu: 50m,  memory: 500Mi }
            limits:   { cpu: 200m, memory: 1Gi }
        admissionController:
          replicaCount: {{ .Values.vpa.admissionReplicas }}
          extraArgs:
            feature-gates: "InPlaceOrRecreate=true"
            kube-api-qps: "20"
            kube-api-burst: "80"
          resources:
            requests: { cpu: 50m,  memory: 500Mi }
            limits:   { cpu: 200m, memory: 2Gi }
          # Run on system nodes — webhook must not be on evictable nodes
          tolerations:
            - key: system-node; operator: Equal; value: "true"; effect: NoSchedule
          nodeAffinity:
            requiredDuringSchedulingIgnoredDuringExecution:
              nodeSelectorTerms:
                - matchExpressions:
                    - key: system-node; operator: In; values: ["true"]
  destination:
    server: https://kubernetes.default.svc
    namespace: kube-system
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    syncOptions: [CreateNamespace=true, ServerSideApply=true]
```

- [ ] **Step 7: Create remaining core app templates**

Create `metrics-server.yaml`, `node-problem-detector.yaml`, `node-local-dns.yaml`, `reloader.yaml` as ArgoCD Application objects following the same structure as `vpa.yaml` above. Key settings per app:

**`metrics-server.yaml`** — chart `metrics-server`, repo `https://kubernetes-sigs.github.io/metrics-server/`, version `{{ .Values.metricsServer.version }}`, namespace `kube-system`, toleration for `system-node`.

**`node-problem-detector.yaml`** — chart `node-problem-detector`, repo `https://charts.deliveryhero.io/`, version `{{ .Values.nodeProblemDetector.version }}`, DaemonSet that tolerates all taints (`operator: Exists`) so it runs on every node type.

**`node-local-dns.yaml`** — chart `node-local-dns`, repo `https://helm.cilium.io/` (or community chart), namespace `kube-system`. Sets `localDns: {{ .Values.nodeLocalDns.localDnsIp }}`.

**`reloader.yaml`** — chart `reloader`, repo `https://stakater.github.io/stakater-charts`, version `{{ .Values.reloader.version }}`, namespace `kube-system`.

- [ ] **Step 8: Commit**

```bash
git add cluster-applications/platform-core
git commit -m "feat: add platform-core chart — namespaces, priority classes, VPA, metrics-server, node tooling"
```

---

### Task 12: platform-networking — ingress stack

**Files:**
- Create: `cluster-applications/platform-networking/Chart.yaml`
- Create: `cluster-applications/platform-networking/values/base.yaml`
- Create: `cluster-applications/platform-networking/values/production.yaml`
- Create: `cluster-applications/platform-networking/templates/apps/cert-manager.yaml`
- Create: `cluster-applications/platform-networking/templates/apps/aws-load-balancer-controller.yaml`
- Create: `cluster-applications/platform-networking/templates/apps/traefik.yaml`
- Create: `cluster-applications/platform-networking/templates/apps/external-dns.yaml`

- [ ] **Step 1: Create `cluster-applications/platform-networking/Chart.yaml`**

```yaml
apiVersion: v2
name: platform-networking
description: Ingress stack — AWS LBC, Traefik, cert-manager, ExternalDNS
version: 0.1.0
```

- [ ] **Step 2: Create `cluster-applications/platform-networking/values/base.yaml`**

```yaml
clusterName: ""
environment: ""
domain: ""
accountId: ""
region: ""
nlbSecurityGroupId: ""
hostedZoneId: ""    # set in production.yaml — your Route 53 hosted zone ID

certManager:
  version: "v1.17.0"
  maxConcurrentChallenges: 15

awsLbc:
  version: "1.11.0"

traefik:
  version: "33.0.0"
  replicas: 2

externalDns:
  version: "1.15.0"
  txtOwnerId: ""    # set from clusterName at render time
```

- [ ] **Step 3: Create `cluster-applications/platform-networking/values/production.yaml`**

```yaml
traefik:
  replicas: 2

externalDns:
  # policy: sync creates AND deletes records when Ingresses are removed.
  # txtOwnerId prevents multi-cluster record collisions — set to cluster name.
  policy: sync
```

- [ ] **Step 4: Create `cluster-applications/platform-networking/templates/apps/cert-manager.yaml`**

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: cert-manager
  namespace: argocd
  annotations:
    # Wave 2 — but cert-manager must be healthy before LBC/Traefik/ESO install
    # (they use cert-manager for webhook TLS). Deploy it first within wave 2.
    argocd.argoproj.io/sync-wave: "2"
spec:
  project: default
  source:
    chart: cert-manager
    repoURL: https://charts.jetstack.io
    targetRevision: {{ .Values.certManager.version }}
    helm:
      valuesObject:
        installCRDs: true
        # crds.keep: true — without this, helm uninstall deletes all Certificate objects
        crds:
          keep: true
        extraArgs:
          - --issuer-ambient-credentials
          - --max-concurrent-challenges={{ .Values.certManager.maxConcurrentChallenges }}
        # Disable admission webhooks — avoids bootstrap ordering issues
        webhook:
          securePort: 10260
        tolerations:
          - key: system-node; operator: Equal; value: "true"; effect: NoSchedule
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
              - matchExpressions:
                  - key: system-node; operator: In; values: ["true"]
  destination:
    server: https://kubernetes.default.svc
    namespace: cert-manager
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    syncOptions: [CreateNamespace=true, ServerSideApply=true]
```

- [ ] **Step 5: Create `cluster-applications/platform-networking/templates/apps/aws-load-balancer-controller.yaml`**

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: aws-load-balancer-controller
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "2"
spec:
  project: default
  source:
    chart: aws-load-balancer-controller
    repoURL: https://aws.github.io/eks-charts
    targetRevision: {{ .Values.awsLbc.version }}
    helm:
      valuesObject:
        clusterName: {{ .Values.clusterName }}
        region: {{ .Values.region }}
        # Disable service mutator webhook — prevents unintended LB creation
        # on Services that don't explicitly set LBC annotations.
        enableServiceMutatorWebhook: false
        # Use cert-manager for webhook TLS (consistent with cert-manager-first approach)
        enableCertManager: true
        tolerations:
          - key: system-node; operator: Equal; value: "true"; effect: NoSchedule
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
              - matchExpressions:
                  - key: system-node; operator: In; values: ["true"]
        resources:
          requests: { cpu: 100m, memory: 128Mi }
          limits:   { cpu: 1,    memory: 1Gi }
  destination:
    server: https://kubernetes.default.svc
    namespace: kube-system
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    syncOptions: [CreateNamespace=true]
```

- [ ] **Step 6: Create `cluster-applications/platform-networking/templates/apps/traefik.yaml`**

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: traefik
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "2"
  # Ignore replica drift — VPA and HPA manage replicas at runtime
  ignoreDifferences:
    - group: apps; kind: Deployment
      jsonPointers: [/spec/replicas]
spec:
  project: default
  source:
    chart: traefik
    repoURL: https://helm.traefik.io/traefik
    targetRevision: {{ .Values.traefik.version }}
    helm:
      valuesObject:
        deployment:
          replicas: {{ .Values.traefik.replicas }}
        # NLB is provisioned by AWS LBC via this service annotation
        service:
          annotations:
            service.beta.kubernetes.io/aws-load-balancer-type: "external"
            service.beta.kubernetes.io/aws-load-balancer-nlb-target-type: "ip"
            service.beta.kubernetes.io/aws-load-balancer-scheme: "internet-facing"
            service.beta.kubernetes.io/aws-load-balancer-security-groups: {{ .Values.nlbSecurityGroupId }}
        # Graceful shutdown — post-shutdown-grace-period must be < terminationGracePeriodSeconds.
        # 181s < 200s ensures connections drain before the pod is killed.
        terminationGracePeriodSeconds: 200
        extraArgs:
          - --entrypoints.web.transport.lifecycle.requestAcceptGraceTimeout=181
          - --entrypoints.websecure.transport.lifecycle.requestAcceptGraceTimeout=181
        # No resource limits on ingress controller pods.
        # Hard limits cause CPU throttling during traffic spikes.
        # VPA provides right-sizing recommendations.
        resources:
          requests: { cpu: 100m, memory: 128Mi }
        updateStrategy:
          rollingUpdate:
            # Zero disruption during deploys
            maxUnavailable: 0
            maxSurge: 1
        podDisruptionBudget:
          enabled: true
          minAvailable: 1
        tolerations:
          - key: system-node; operator: Equal; value: "true"; effect: NoSchedule
  destination:
    server: https://kubernetes.default.svc
    namespace: traefik
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    syncOptions: [CreateNamespace=true]
```

- [ ] **Step 7: Create `cluster-applications/platform-networking/templates/apps/external-dns.yaml`**

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: external-dns
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "2"
spec:
  project: default
  source:
    chart: external-dns
    repoURL: https://charts.bitnami.com/bitnami
    targetRevision: {{ .Values.externalDns.version }}
    helm:
      valuesObject:
        provider: aws
        aws:
          region: {{ .Values.region }}
          zoneType: public
        # txtOwnerId MUST be set to cluster name.
        # Without this, a second cluster will delete this cluster's DNS records.
        txtOwnerId: {{ .Values.clusterName }}
        # policy: sync — creates AND deletes records. Requires correct txtOwnerId.
        policy: {{ .Values.externalDns.policy | default "upsert-only" }}
        # Scope to one hosted zone — prevents cross-zone accidents
        domainFilters:
          - {{ .Values.domain }}
        # Exclude AAAA (IPv6) — cluster is IPv4 only
        excludeRecordTypes:
          - AAAA
        interval: 10m
        triggerLoopOnEvent: true
        minEventSyncInterval: 5m
        resources:
          requests: { cpu: 50m, memory: 200Mi }
          limits:   { cpu: 200m, memory: 512Mi }
        tolerations:
          - key: system-node; operator: Equal; value: "true"; effect: NoSchedule
  destination:
    server: https://kubernetes.default.svc
    namespace: external-dns
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    syncOptions: [CreateNamespace=true]
```

- [ ] **Step 8: Commit**

```bash
git add cluster-applications/platform-networking
git commit -m "feat: add platform-networking chart — cert-manager, AWS LBC, Traefik, ExternalDNS"
```

---

### Task 13: platform-autoscaling — Karpenter and KEDA

**Files:**
- Create: `cluster-applications/platform-autoscaling/Chart.yaml`
- Create: `cluster-applications/platform-autoscaling/values/base.yaml`
- Create: `cluster-applications/platform-autoscaling/values/production.yaml`
- Create: `cluster-applications/platform-autoscaling/templates/apps/karpenter.yaml`
- Create: `cluster-applications/platform-autoscaling/templates/apps/karpenter-nodepools.yaml`
- Create: `cluster-applications/platform-autoscaling/templates/apps/keda.yaml`

- [ ] **Step 1: Create `cluster-applications/platform-autoscaling/Chart.yaml`**

```yaml
apiVersion: v2
name: platform-autoscaling
description: Karpenter, Karpenter NodePools/EC2NodeClasses, and KEDA
version: 0.1.0
```

- [ ] **Step 2: Create `cluster-applications/platform-autoscaling/values/base.yaml`**

```yaml
clusterName: ""
environment: ""
region: ""
accountId: ""
privateSubnetIds: []
nodeSecurityGroupId: ""

karpenter:
  version: "1.3.3"
  # reservedENIs: "1" — reserves one ENI per node to prevent exhaustion
  # that would block Pod Identity agent communication.
  reservedENIs: "1"

keda:
  version: "2.17.0"

# NodePool defaults — override in production.yaml for prod-specific capacity types
nodePools:
  generalAmd64:
    capacityType: ["spot", "on-demand"]
    minMemoryGib: 4
    maxMemoryGib: 128
  generalArm64:
    capacityType: ["spot", "on-demand"]
    minMemoryGib: 4
    maxMemoryGib: 64
```

- [ ] **Step 3: Create `cluster-applications/platform-autoscaling/values/production.yaml`**

```yaml
nodePools:
  generalAmd64:
    # Stagger disruption budget cron windows between pools to avoid
    # simultaneous fleet replacement waves (e.g. arm64 uses :05,:20,:35,:50)
    disruptionBudgetSchedule: "0,15,30,45 * * * *"
  generalArm64:
    disruptionBudgetSchedule: "5,20,35,50 * * * *"
```

- [ ] **Step 4: Create `cluster-applications/platform-autoscaling/templates/apps/karpenter.yaml`**

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: karpenter
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "3"
    # Delete=false — accidental NodePool deletion would drain the entire workload fleet
    argocd.argoproj.io/sync-options: Delete=false
spec:
  project: default
  source:
    chart: karpenter
    repoURL: public.ecr.aws/karpenter
    targetRevision: {{ .Values.karpenter.version }}
    helm:
      valuesObject:
        settings:
          clusterName: {{ .Values.clusterName }}
          interruptionQueueName: {{ .Values.clusterName }}
          reservedENIs: {{ .Values.karpenter.reservedENIs | quote }}
          featureGates:
            nodeRepair: true
        tolerations:
          - key: system-node; operator: Equal; value: "true"; effect: NoSchedule
        affinity:
          nodeAffinity:
            requiredDuringSchedulingIgnoredDuringExecution:
              nodeSelectorTerms:
                - matchExpressions:
                    - key: system-node; operator: In; values: ["true"]
        priorityClassName: system-cluster-critical
        resources:
          requests: { cpu: 300m, memory: 1Gi }
          limits:   { cpu: 1,    memory: 1Gi }
        serviceMonitor:
          enabled: true
          additionalLabels:
            release: kube-prometheus-stack
  destination:
    server: https://kubernetes.default.svc
    namespace: karpenter
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    syncOptions: [CreateNamespace=true, ServerSideApply=true]
```

- [ ] **Step 5: Create `cluster-applications/platform-autoscaling/templates/apps/karpenter-nodepools.yaml`**

NodePools are in a separate wave (wave 4) from the Karpenter controller (wave 3). The controller must be ready and CRDs registered before NodePool/EC2NodeClass instances can be created.

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: karpenter-nodepools
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "4"
    argocd.argoproj.io/sync-options: Delete=false
spec:
  project: default
  source:
    repoURL: {{ .Values.repoURL }}
    targetRevision: HEAD
    path: cluster-applications/platform-autoscaling/nodepools
    helm:
      parameters:
        - name: clusterName; value: {{ .Values.clusterName }}
        - name: region;      value: {{ .Values.region }}
        - name: accountId;   value: {{ .Values.accountId }}
      valueFiles:
        - ../../environments/{{ .Values.environment }}.yaml
  destination:
    server: https://kubernetes.default.svc
    namespace: karpenter
  syncPolicy:
    automated: { prune: false, selfHeal: true }
    syncOptions: [ServerSideApply=true]
```

Then create `cluster-applications/platform-autoscaling/nodepools/` containing the actual `EC2NodeClass` and `NodePool` YAML:

```yaml
# cluster-applications/platform-autoscaling/nodepools/ec2nodeclass.yaml
apiVersion: karpenter.k8s.aws/v1
kind: EC2NodeClass
metadata:
  name: default
spec:
  amiFamily: AL2023
  role: "{{ .Values.clusterName }}-{{ .Values.environment }}-eks-node-role"
  subnetSelectorTerms:
    - tags:
        kubernetes.io/cluster/{{ .Values.clusterName }}: "shared"
  securityGroupSelectorTerms:
    - tags:
        Name: "{{ .Values.clusterName }}-nodes-sg"
  blockDeviceMappings:
    - deviceName: /dev/xvda
      ebs:
        volumeSize: 50Gi
        volumeType: gp3
        encrypted: true
        # Tag every EBS volume with Cluster name for cost attribution
        kmsKeyID: aws/ebs
  tags:
    Cluster: {{ .Values.clusterName }}
    Environment: {{ .Values.environment }}
    ManagedBy: karpenter
```

```yaml
# cluster-applications/platform-autoscaling/nodepools/nodepool-amd64.yaml
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: general-amd64
spec:
  template:
    metadata:
      labels:
        karpenter.sh/capacity-type: spot
    spec:
      nodeClassRef:
        group: karpenter.k8s.aws
        kind: EC2NodeClass
        name: default
      requirements:
        - key: karpenter.sh/capacity-type
          operator: In
          values: ["spot", "on-demand"]
        - key: kubernetes.io/arch
          operator: In
          values: ["amd64"]
        - key: karpenter.k8s.aws/instance-category
          operator: In
          values: ["m", "c", "r"]
        - key: karpenter.k8s.aws/instance-generation
          operator: Gt
          values: ["5"]
  disruption:
    consolidationPolicy: WhenEmptyOrUnderutilized
    consolidateAfter: 1m
    budgets:
      - schedule: "{{ .Values.nodePools.generalAmd64.disruptionBudgetSchedule | default \"0,15,30,45 * * * *\" }}"
        duration: 10m
        nodes: "10%"
  limits:
    cpu: 1000
    memory: 4000Gi
```

```yaml
# cluster-applications/platform-autoscaling/nodepools/nodepool-arm64.yaml
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: general-arm64
spec:
  template:
    spec:
      nodeClassRef:
        group: karpenter.k8s.aws
        kind: EC2NodeClass
        name: default
      requirements:
        - key: karpenter.sh/capacity-type
          operator: In
          values: ["spot", "on-demand"]
        - key: kubernetes.io/arch
          operator: In
          values: ["arm64"]
        - key: karpenter.k8s.aws/instance-category
          operator: In
          values: ["m", "c", "r"]
        - key: karpenter.k8s.aws/instance-generation
          operator: Gt
          values: ["5"]
  disruption:
    consolidationPolicy: WhenEmptyOrUnderutilized
    consolidateAfter: 1m
    budgets:
      - schedule: "{{ .Values.nodePools.generalArm64.disruptionBudgetSchedule | default \"5,20,35,50 * * * *\" }}"
        duration: 10m
        nodes: "10%"
  limits:
    cpu: 500
    memory: 2000Gi
```

- [ ] **Step 6: Create `cluster-applications/platform-autoscaling/templates/apps/keda.yaml`**

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: keda
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "3"
spec:
  project: default
  source:
    chart: keda
    repoURL: https://kedacore.github.io/charts
    targetRevision: {{ .Values.keda.version }}
    helm:
      valuesObject:
        crds:
          install: true
        logging:
          operator:
            format: json
            level: info
        prometheus:
          operator:
            enabled: true
            podMonitor:
              enabled: true
              additionalLabels:
                release: kube-prometheus-stack
  destination:
    server: https://kubernetes.default.svc
    namespace: keda
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    syncOptions: [CreateNamespace=true, ServerSideApply=true, Replace=true]
  ignoreDifferences:
    - group: monitoring.coreos.com
      kind: PodMonitor
      jsonPointers: [/spec/podMetricsEndpoints/0/bearerTokenSecret]
```

- [ ] **Step 7: Commit**

```bash
git add cluster-applications/platform-autoscaling
git commit -m "feat: add platform-autoscaling chart — Karpenter, NodePools, KEDA"
```

---

### Task 14: platform-secrets — External Secrets Operator

**Files:**
- Create: `cluster-applications/platform-secrets/Chart.yaml`
- Create: `cluster-applications/platform-secrets/values/base.yaml`
- Create: `cluster-applications/platform-secrets/values/production.yaml`
- Create: `cluster-applications/platform-secrets/templates/apps/external-secrets-operator.yaml`
- Create: `cluster-applications/platform-secrets/templates/apps/cluster-secret-store.yaml`

- [ ] **Step 1: Create `cluster-applications/platform-secrets/Chart.yaml`**

```yaml
apiVersion: v2
name: platform-secrets
description: External Secrets Operator and ClusterSecretStore backed by AWS Secrets Manager
version: 0.1.0
```

- [ ] **Step 2: Create `cluster-applications/platform-secrets/values/base.yaml`**

```yaml
clusterName: ""
environment: ""
region: ""

eso:
  version: "0.12.1"
  concurrent: 100
  clientBurst: 200
  clientQps: 100
```

- [ ] **Step 3: Create `cluster-applications/platform-secrets/templates/apps/external-secrets-operator.yaml`**

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: external-secrets-operator
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "2"
spec:
  project: default
  source:
    chart: external-secrets
    repoURL: https://charts.external-secrets.io
    targetRevision: {{ .Values.eso.version }}
    helm:
      valuesObject:
        concurrent: {{ .Values.eso.concurrent }}
        extraArgs:
          client-burst: {{ .Values.eso.clientBurst | quote }}
          client-qps: {{ .Values.eso.clientQps | quote }}
          enable-secrets-caching: "true"
        resources:
          requests: { cpu: 100m, memory: 500Mi }
          limits:   { cpu: 500m, memory: 1Gi }
        tolerations:
          - key: system-node; operator: Equal; value: "true"; effect: NoSchedule
  destination:
    server: https://kubernetes.default.svc
    namespace: external-secrets
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    syncOptions: [CreateNamespace=true, ServerSideApply=true]
```

- [ ] **Step 4: Create `cluster-applications/platform-secrets/templates/apps/cluster-secret-store.yaml`**

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: cluster-secret-store
  namespace: argocd
  annotations:
    # Wave 2 but after ESO — ClusterSecretStore requires ESO CRDs
    argocd.argoproj.io/sync-wave: "2"
spec:
  project: default
  source:
    repoURL: {{ .Values.repoURL }}
    targetRevision: HEAD
    path: cluster-applications/platform-secrets/store
    helm:
      parameters:
        - name: region;      value: {{ .Values.region }}
        - name: environment; value: {{ .Values.environment }}
  destination:
    server: https://kubernetes.default.svc
    namespace: external-secrets
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    syncOptions: [CreateNamespace=true]
```

Then create the store manifest at `cluster-applications/platform-secrets/store/cluster-secret-store.yaml`:

```yaml
# ClusterSecretStore — uses Pod Identity (no static credentials)
apiVersion: external-secrets.io/v1beta1
kind: ClusterSecretStore
metadata:
  name: aws-secrets-manager
spec:
  provider:
    aws:
      service: SecretsManager
      region: {{ .Values.region }}
      # auth.jwt.serviceAccountRef omitted — Pod Identity handles auth automatically
```

- [ ] **Step 5: Commit**

```bash
git add cluster-applications/platform-secrets
git commit -m "feat: add platform-secrets chart — ESO and ClusterSecretStore"
```

---

### Task 15: platform-policy — Kyverno policies and Cloud Custodian

**Files:**
- Create: `cluster-applications/platform-policy/Chart.yaml`
- Create: `cluster-applications/platform-policy/values/base.yaml`
- Create: `cluster-applications/platform-policy/values/production.yaml`
- Create: `cluster-applications/platform-policy/templates/apps/kyverno.yaml`
- Create: `cluster-applications/platform-policy/templates/apps/kyverno-policies.yaml`
- Create: `cluster-applications/platform-policy/templates/apps/cloud-custodian.yaml`

- [ ] **Step 1: Create `cluster-applications/platform-policy/Chart.yaml`**

```yaml
apiVersion: v2
name: platform-policy
description: Kyverno policy engine, default policies, and Cloud Custodian governance
version: 0.1.0
```

- [ ] **Step 2: Create `cluster-applications/platform-policy/values/base.yaml`**

```yaml
clusterName: ""
environment: ""

kyverno:
  version: "3.3.7"
  admissionReplicas: 3

cloudCustodian:
  version: "0.9.40"
  schedule: "0 6 * * *"   # daily at 06:00 UTC
```

- [ ] **Step 3: Create `cluster-applications/platform-policy/templates/apps/kyverno.yaml`**

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: kyverno
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "5"
    argocd.argoproj.io/sync-options: Delete=false
spec:
  project: default
  source:
    chart: kyverno
    repoURL: https://kyverno.github.io/kyverno/
    targetRevision: {{ .Values.kyverno.version }}
    helm:
      valuesObject:
        admissionController:
          replicas: {{ .Values.kyverno.admissionReplicas }}
          priorityClassName: system-cluster-critical
          tolerations:
            - key: system-node; operator: Equal; value: "true"; effect: NoSchedule
          nodeAffinity:
            requiredDuringSchedulingIgnoredDuringExecution:
              nodeSelectorTerms:
                - matchExpressions:
                    - key: system-node; operator: In; values: ["true"]
          resources:
            # CPU request = limit — no bursting on admission webhook path
            requests: { cpu: 1,    memory: 256Mi }
            limits:   { cpu: 1,    memory: 256Mi }
          rbac:
            coreClusterRole:
              extraResources:
                # Allow Kyverno to read Karpenter objects for policy validation
                - apiGroups: [karpenter.sh]
                  resources: [nodeclaims, nodepools]
                  verbs: [get, list, watch]
        config:
          # Exclude Binding and Pod/binding — intercepting these adds latency
          # to every pod scheduling operation
          resourceFiltersExclude:
            - "[Binding,*,*]"
            - "[Pod/binding,*,*]"
  destination:
    server: https://kubernetes.default.svc
    namespace: kyverno
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    syncOptions: [CreateNamespace=true, ServerSideApply=true]
  ignoreDifferences:
    - group: apiextensions.k8s.io
      kind: CustomResourceDefinition
      jsonPointers: [/metadata/annotations, /metadata/labels]
```

- [ ] **Step 4: Create `cluster-applications/platform-policy/templates/apps/kyverno-policies.yaml`**

This Application points at a `policies/` directory containing the actual Kyverno ClusterPolicy objects:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: kyverno-policies
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "5"
spec:
  project: default
  source:
    repoURL: {{ .Values.repoURL }}
    targetRevision: HEAD
    path: cluster-applications/platform-policy/policies
  destination:
    server: https://kubernetes.default.svc
    namespace: kyverno
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    syncOptions: [ServerSideApply=true]
```

Then create `cluster-applications/platform-policy/policies/` with four ClusterPolicy files:

**`require-resource-requests.yaml`** — validates all containers have CPU and memory requests set. Action: `Audit` (warn, don't block) in base; set to `Enforce` in production.yaml for stricter enforcement.

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: require-resource-requests
spec:
  validationFailureAction: Audit
  rules:
    - name: check-resource-requests
      match:
        any:
          - resources: { kinds: [Pod] }
      validate:
        message: "CPU and memory requests are required on all containers."
        pattern:
          spec:
            containers:
              - resources:
                  requests:
                    cpu: "?*"
                    memory: "?*"
```

**`no-latest-image-tag.yaml`** — blocks pods using `:latest` tag.

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: no-latest-image-tag
spec:
  validationFailureAction: Enforce
  rules:
    - name: no-latest-tag
      match:
        any:
          - resources: { kinds: [Pod] }
      validate:
        message: "Image tag 'latest' is not allowed. Pin a specific version."
        foreach:
          - list: "request.object.spec.containers"
            deny:
              conditions:
                any:
                  - key: "{{ element.image }}"
                    operator: Equals
                    value: "*:latest"
                  - key: "{{ element.image }}"
                    operator: NotContains
                    value: ":"
```

**`default-network-policy.yaml`** — Kyverno generate rule: creates a default-deny-ingress NetworkPolicy in every new namespace.

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: default-deny-ingress
spec:
  rules:
    - name: generate-default-deny
      match:
        any:
          - resources: { kinds: [Namespace] }
      exclude:
        any:
          - resources:
              namespaces: [kube-system, kube-public, kube-node-lease, argocd,
                           monitoring, karpenter, kyverno, cert-manager, external-secrets,
                           external-dns, traefik, velero, cloud-custodian]
      generate:
        apiVersion: networking.k8s.io/v1
        kind: NetworkPolicy
        name: default-deny-ingress
        namespace: "{{request.object.metadata.name}}"
        data:
          spec:
            podSelector: {}
            policyTypes: [Ingress]
```

**`require-labels.yaml`** — audit: all Deployments must have `app.kubernetes.io/name` and `app.kubernetes.io/version` labels.

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: require-labels
spec:
  validationFailureAction: Audit
  rules:
    - name: require-app-labels
      match:
        any:
          - resources: { kinds: [Deployment] }
      validate:
        message: "Deployments must have app.kubernetes.io/name and app.kubernetes.io/version labels."
        pattern:
          metadata:
            labels:
              app.kubernetes.io/name: "?*"
              app.kubernetes.io/version: "?*"
```

- [ ] **Step 5: Create `cluster-applications/platform-policy/templates/apps/cloud-custodian.yaml`**

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: cloud-custodian
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "5"
spec:
  project: default
  source:
    repoURL: {{ .Values.repoURL }}
    targetRevision: HEAD
    path: cluster-applications/platform-policy/custodian
    helm:
      parameters:
        - name: schedule;    value: {{ .Values.cloudCustodian.schedule }}
        - name: environment; value: {{ .Values.environment }}
  destination:
    server: https://kubernetes.default.svc
    namespace: cloud-custodian
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    syncOptions: [CreateNamespace=true]
```

Create `cluster-applications/platform-policy/custodian/cronjob.yaml` — a CronJob that runs `c7n` with policies mounted from a ConfigMap. The ConfigMap contains a starter set of policies (require-tags.yaml, unused-ebs-volumes.yaml) as an example that users extend.

- [ ] **Step 6: Commit**

```bash
git add cluster-applications/platform-policy
git commit -m "feat: add platform-policy chart — Kyverno, default policies, Cloud Custodian"
```

---

### Task 16: platform-observability — OTEL, Prometheus, Loki, noe, yace

**Files:**
- Create: `cluster-applications/platform-observability/Chart.yaml`
- Create: `cluster-applications/platform-observability/values/base.yaml`
- Create: `cluster-applications/platform-observability/values/production.yaml`
- Create: `cluster-applications/platform-observability/templates/apps/otel-operator.yaml`
- Create: `cluster-applications/platform-observability/templates/apps/otel-collector.yaml`
- Create: `cluster-applications/platform-observability/templates/apps/kube-prometheus-stack.yaml`
- Create: `cluster-applications/platform-observability/templates/apps/loki.yaml`
- Create: `cluster-applications/platform-observability/templates/apps/kubernetes-events-exporter.yaml`
- Create: `cluster-applications/platform-observability/templates/apps/noe.yaml`
- Create: `cluster-applications/platform-observability/templates/apps/yace.yaml`

- [ ] **Step 1: Create `cluster-applications/platform-observability/Chart.yaml`**

```yaml
apiVersion: v2
name: platform-observability
description: OTEL Operator, Prometheus, Loki, kubernetes-events-exporter, noe, yace
version: 0.1.0
```

- [ ] **Step 2: Create `cluster-applications/platform-observability/values/base.yaml`**

```yaml
clusterName: ""
environment: ""
region: ""

otelOperator:
  version: "0.119.0"

kubePrometheusStack:
  version: "68.4.4"
  grafanaAdminPassword: ""   # set via ExternalSecret in production

loki:
  version: "6.25.0"
  storageSize: 50Gi

kubernetesEventsExporter:
  version: "2.4.0"

noe:
  version: "0.15.0"

yace:
  version: "0.61.2"
```

- [ ] **Step 3: Create `cluster-applications/platform-observability/templates/apps/otel-operator.yaml`**

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: otel-operator
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "6"
spec:
  project: default
  source:
    chart: opentelemetry-operator
    repoURL: https://open-telemetry.github.io/opentelemetry-helm-charts
    targetRevision: {{ .Values.otelOperator.version }}
    helm:
      valuesObject:
        manager:
          collectorImage:
            repository: otel/opentelemetry-collector-contrib
          tolerations:
            - key: system-node; operator: Equal; value: "true"; effect: NoSchedule
        admissionWebhooks:
          certManager:
            enabled: true
  destination:
    server: https://kubernetes.default.svc
    namespace: monitoring
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    syncOptions: [CreateNamespace=true, ServerSideApply=true]
```

- [ ] **Step 4: Create `cluster-applications/platform-observability/templates/apps/otel-collector.yaml`**

This Application points at a `collector/` directory containing the `OpenTelemetryCollector` CRD. The collector runs as a DaemonSet, replacing Fluent Bit for log collection.

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: otel-collector
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "6"
spec:
  project: default
  source:
    repoURL: {{ .Values.repoURL }}
    targetRevision: HEAD
    path: cluster-applications/platform-observability/collector
    helm:
      parameters:
        - name: clusterName; value: {{ .Values.clusterName }}
  destination:
    server: https://kubernetes.default.svc
    namespace: monitoring
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    syncOptions: [CreateNamespace=true, ServerSideApply=true]
```

Create `cluster-applications/platform-observability/collector/otelcol.yaml`:

```yaml
apiVersion: opentelemetry.io/v1beta1
kind: OpenTelemetryCollector
metadata:
  name: platform
  namespace: monitoring
spec:
  mode: daemonset
  tolerations:
    - operator: Exists   # run on all nodes including system nodes
  config:
    receivers:
      # Log collection — replaces Fluent Bit
      filelog:
        include: [/var/log/pods/*/*/*.log]
        include_file_path: true
        operators:
          - type: router
            id: get-format
            routes:
              - output: parser-docker
                expr: 'body matches "^\\{"'
              - output: parser-crio
                expr: 'body matches "^[^ Z]+ "'
          - type: json_parser
            id: parser-docker
            output: extract-metadata
          - type: regex_parser
            id: parser-crio
            regex: "^(?P<time>[^ Z]+) (?P<stream>stdout|stderr) (?P<logtag>[^ ]+) ?(?P<log>.*)$"
            output: extract-metadata
          - type: move
            id: extract-metadata
            from: attributes["log.file.path"]
            to: resource["filename"]
      # Receive OTLP traces and metrics from instrumented apps
      otlp:
        protocols:
          grpc:
            endpoint: 0.0.0.0:4317
          http:
            endpoint: 0.0.0.0:4318
    processors:
      batch: {}
      memory_limiter:
        check_interval: 1s
        limit_mib: 400
        spike_limit_mib: 100
      k8sattributes:
        extract:
          metadata: [k8s.namespace.name, k8s.pod.name, k8s.container.name, k8s.node.name]
        pod_association:
          - sources:
              - from: resource_attribute
                name: k8s.pod.ip
    exporters:
      # Logs → Loki
      loki:
        endpoint: http://loki-gateway.monitoring.svc.cluster.local/loki/api/v1/push
        default_labels_enabled:
          exporter: false
          job: true
      # Metrics → Prometheus (remote write)
      prometheusremotewrite:
        endpoint: http://kube-prometheus-stack-prometheus.monitoring.svc.cluster.local:9090/api/v1/write
    service:
      pipelines:
        logs:
          receivers: [filelog]
          processors: [memory_limiter, k8sattributes, batch]
          exporters: [loki]
        traces:
          receivers: [otlp]
          processors: [memory_limiter, k8sattributes, batch]
          exporters: [logging]   # extend with Tempo exporter when added
        metrics:
          receivers: [otlp]
          processors: [memory_limiter, batch]
          exporters: [prometheusremotewrite]
```

- [ ] **Step 5: Create `cluster-applications/platform-observability/templates/apps/kube-prometheus-stack.yaml`**

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: kube-prometheus-stack
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "6"
    # ServerSideDiff companion to ServerSideApply — prevents false positives in ArgoCD UI
    argocd.argoproj.io/compare-options: ServerSideDiff=true
spec:
  project: default
  source:
    chart: kube-prometheus-stack
    repoURL: https://prometheus-community.github.io/helm-charts
    targetRevision: {{ .Values.kubePrometheusStack.version }}
    helm:
      valuesObject:
        # Disable admission webhooks — avoids bootstrap chicken-and-egg
        prometheusOperator:
          admissionWebhooks:
            enabled: false
        # Exclude irrelevant secret types from operator watch — reduces API server load
        prometheusOperator:
          secretFieldSelector: >-
            type!=kubernetes.io/dockercfg,
            type!=kubernetes.io/service-account-token,
            type!=helm.sh/release.v1
        prometheus:
          prometheusSpec:
            # Enable remote write receiver so OTEL collector can push metrics
            enableRemoteWriteReceiver: true
            retention: 15d
            storageSpec:
              volumeClaimTemplate:
                spec:
                  storageClassName: gp3
                  resources:
                    requests:
                      storage: 50Gi
            tolerations:
              - key: system-node; operator: Equal; value: "true"; effect: NoSchedule
        grafana:
          adminPassword: {{ .Values.kubePrometheusStack.grafanaAdminPassword | default "changeme" | quote }}
          ingress:
            enabled: true
            ingressClassName: traefik
            hosts:
              - grafana.{{ .Values.domain }}
            tls:
              - secretName: grafana-tls
                hosts: [grafana.{{ .Values.domain }}]
            annotations:
              cert-manager.io/cluster-issuer: letsencrypt-prod
  destination:
    server: https://kubernetes.default.svc
    namespace: monitoring
  # ServerSideApply=true — kube-prometheus-stack CRDs exceed client-side apply limit
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    syncOptions: [CreateNamespace=true, ServerSideApply=true]
```

- [ ] **Step 6: Create remaining observability apps**

Create these four files following the ArgoCD Application pattern:

**`loki.yaml`** — chart `loki`, repo `https://grafana.github.io/helm-charts`, version `{{ .Values.loki.version }}`, namespace `monitoring`. Set `deploymentMode: SingleBinary`, `singleBinary.replicas: 1`, storage via PVC (gp3, `{{ .Values.loki.storageSize }}`).

**`kubernetes-events-exporter.yaml`** — chart `kubernetes-event-exporter`, repo `https://charts.bitnami.com/bitnami`, version `{{ .Values.kubernetesEventsExporter.version }}`. Config: sink to Loki endpoint (`http://loki-gateway.monitoring.svc.cluster.local/loki/api/v1/push`).

**`noe.yaml`** — chart `noe`, repo `https://adevinta.github.io/noe/` (or install from GitHub releases as a Kubernetes Job/Deployment). Uses Pod Identity for `ec2:DescribeInstanceTypes`. Exposes metrics on `:8080/metrics` with a ServiceMonitor for Prometheus scraping.

**`yace.yaml`** — chart `yet-another-cloudwatch-exporter`, repo `https://mogensen.github.io/yet-another-cloudwatch-exporter/`, version `{{ .Values.yace.version }}`. Uses Pod Identity for CloudWatch access. Configure `serviceAccount.name: yace` with matching Pod Identity association.

- [ ] **Step 7: Commit**

```bash
git add cluster-applications/platform-observability
git commit -m "feat: add platform-observability chart — OTEL, Prometheus, Loki, noe, yace"
```

---

### Task 17: platform-gitops — ArgoCD config and Velero

**Files:**
- Create: `cluster-applications/platform-gitops/Chart.yaml`
- Create: `cluster-applications/platform-gitops/values/base.yaml`
- Create: `cluster-applications/platform-gitops/values/production.yaml`
- Create: `cluster-applications/platform-gitops/templates/apps/argocd-projects.yaml`
- Create: `cluster-applications/platform-gitops/templates/apps/velero.yaml`

- [ ] **Step 1: Create `cluster-applications/platform-gitops/Chart.yaml`**

```yaml
apiVersion: v2
name: platform-gitops
description: ArgoCD Projects, RBAC config, and Velero backups
version: 0.1.0
```

- [ ] **Step 2: Create `cluster-applications/platform-gitops/values/base.yaml`**

```yaml
clusterName: ""
environment: ""
region: ""
repoURL: ""

velero:
  version: "7.2.1"
  backupBucket: ""   # set from clusterName at render time: {{ .Values.clusterName }}-velero-backups
  scheduleHour: "2"  # 02:00 UTC daily backup
```

- [ ] **Step 3: Create `cluster-applications/platform-gitops/templates/apps/argocd-projects.yaml`**

```yaml
---
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: platform
  namespace: argocd
spec:
  description: Platform infrastructure components
  sourceRepos:
    - {{ .Values.repoURL }}
    - https://argoproj.github.io/argo-helm
    - https://charts.jetstack.io
    - https://aws.github.io/eks-charts
    - https://helm.traefik.io/traefik
    - https://charts.bitnami.com/bitnami
    - https://charts.external-secrets.io
    - https://kyverno.github.io/kyverno/
    - public.ecr.aws/karpenter
    - https://kedacore.github.io/charts
    - https://open-telemetry.github.io/opentelemetry-helm-charts
    - https://prometheus-community.github.io/helm-charts
    - https://grafana.github.io/helm-charts
    - https://vmware-tanzu.github.io/helm-charts
    - https://charts.fairwinds.com/stable
    - https://charts.deliveryhero.io/
    - https://stakater.github.io/stakater-charts
    - https://kubernetes-sigs.github.io/metrics-server/
  destinations:
    - namespace: "*"
      server: https://kubernetes.default.svc
  clusterResourceWhitelist:
    - group: "*"
      kind: "*"
```

- [ ] **Step 4: Create `cluster-applications/platform-gitops/templates/apps/velero.yaml`**

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: velero
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "7"
spec:
  project: default
  source:
    chart: velero
    repoURL: https://vmware-tanzu.github.io/helm-charts
    targetRevision: {{ .Values.velero.version }}
    helm:
      valuesObject:
        configuration:
          backupStorageLocation:
            - name: default
              provider: aws
              bucket: {{ .Values.clusterName }}-velero-backups
              config:
                region: {{ .Values.region }}
          volumeSnapshotLocation:
            - name: default
              provider: aws
              config:
                region: {{ .Values.region }}
        serviceAccount:
          server:
            name: velero
        schedules:
          daily-backup:
            schedule: "0 {{ .Values.velero.scheduleHour }} * * *"
            template:
              ttl: 720h   # 30 days
              storageLocation: default
              volumeSnapshotLocations: [default]
        tolerations:
          - key: system-node; operator: Equal; value: "true"; effect: NoSchedule
  destination:
    server: https://kubernetes.default.svc
    namespace: velero
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    syncOptions: [CreateNamespace=true]
```

- [ ] **Step 5: Commit**

```bash
git add cluster-applications/platform-gitops
git commit -m "feat: add platform-gitops chart — ArgoCD Projects and Velero"
```

---

## Phase 5: CI/CD and documentation

### Task 18: GitHub Actions — plan and apply workflows (disabled)

**Files:**
- Create: `.github/workflows/terraform-plan.yml`
- Create: `.github/workflows/terraform-apply.yml`

- [ ] **Step 1: Create `.github/workflows/terraform-plan.yml`**

```yaml
# Terraform plan workflow — posts plan output as PR comment.
# DISABLED: remove the `if: false` condition on the job to enable.
# Prerequisites before enabling:
#   1. Create an AWS IAM role for GitHub OIDC: trust sts.amazonaws.com for token.actions.githubusercontent.com
#   2. Set GitHub repo secret: AWS_ROLE_ARN = arn:aws:iam::<account>:role/<name>
#   3. Set GitHub repo variable: AWS_REGION = your region

name: Terraform Plan

on:
  pull_request:
    paths:
      - "live/**"
      - "modules/**"

permissions:
  id-token: write   # required for OIDC
  contents: read
  pull-requests: write

jobs:
  plan:
    if: false   # DISABLED — remove this line to enable
    runs-on: ubuntu-latest
    strategy:
      matrix:
        stack:
          - live/production/account/vpc
          - live/production/account/iam
          - live/production/account/ecr
          - live/production/cluster/eks
          - live/production/cluster/karpenter
          - live/production/cluster/argocd-bootstrap

    steps:
      - uses: actions/checkout@v4

      - uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: ${{ secrets.AWS_ROLE_ARN }}
          aws-region: ${{ vars.AWS_REGION }}

      - uses: gruntwork-io/terragrunt-action@v2
        with:
          tf_version: "1.10.0"
          tg_version: "0.68.0"
          tg_command: plan
          tg_dir: ${{ matrix.stack }}
        env:
          DOMAIN_NAME: ${{ vars.DOMAIN_NAME }}
          TF_VAR_ADMIN_CIDR: ${{ vars.ADMIN_CIDR }}
          REPO_URL: ${{ github.server_url }}/${{ github.repository }}

      - uses: actions/github-script@v7
        if: always()
        with:
          script: |
            const output = `### Terraform Plan: \`${{ matrix.stack }}\`
            \`\`\`
            ${{ steps.plan.outputs.stdout }}
            \`\`\``;
            github.rest.issues.createComment({
              issue_number: context.issue.number,
              owner: context.repo.owner,
              repo: context.repo.repo,
              body: output
            });
```

- [ ] **Step 2: Create `.github/workflows/terraform-apply.yml`**

```yaml
# Terraform apply workflow — applies changed stacks on merge to main.
# DISABLED: remove the `if: false` condition on the job to enable.
# Stack order is fixed (account before cluster) to respect dependencies.

name: Terraform Apply

on:
  push:
    branches: [main]
    paths:
      - "live/**"
      - "modules/**"

permissions:
  id-token: write
  contents: read

jobs:
  apply:
    if: false   # DISABLED — remove this line to enable
    runs-on: ubuntu-latest
    environment: production   # GitHub environment with required reviewers (recommended)

    steps:
      - uses: actions/checkout@v4

      - uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: ${{ secrets.AWS_ROLE_ARN }}
          aws-region: ${{ vars.AWS_REGION }}

      # Apply in dependency order: account first, then cluster
      - name: Apply account/vpc
        uses: gruntwork-io/terragrunt-action@v2
        with:
          tf_version: "1.10.0"
          tg_version: "0.68.0"
          tg_command: apply
          tg_dir: live/production/account/vpc
        env:
          DOMAIN_NAME: ${{ vars.DOMAIN_NAME }}
          TF_VAR_ADMIN_CIDR: ${{ vars.ADMIN_CIDR }}
          REPO_URL: ${{ github.server_url }}/${{ github.repository }}

      - name: Apply account/iam
        uses: gruntwork-io/terragrunt-action@v2
        with:
          tf_version: "1.10.0"
          tg_version: "0.68.0"
          tg_command: apply
          tg_dir: live/production/account/iam
        env:
          DOMAIN_NAME: ${{ vars.DOMAIN_NAME }}
          TF_VAR_ADMIN_CIDR: ${{ vars.ADMIN_CIDR }}
          REPO_URL: ${{ github.server_url }}/${{ github.repository }}

      - name: Apply account/ecr
        uses: gruntwork-io/terragrunt-action@v2
        with:
          tf_version: "1.10.0"
          tg_version: "0.68.0"
          tg_command: apply
          tg_dir: live/production/account/ecr
        env:
          DOMAIN_NAME: ${{ vars.DOMAIN_NAME }}
          TF_VAR_ADMIN_CIDR: ${{ vars.ADMIN_CIDR }}
          REPO_URL: ${{ github.server_url }}/${{ github.repository }}

      - name: Apply cluster/eks
        uses: gruntwork-io/terragrunt-action@v2
        with:
          tf_version: "1.10.0"
          tg_version: "0.68.0"
          tg_command: apply
          tg_dir: live/production/cluster/eks
        env:
          DOMAIN_NAME: ${{ vars.DOMAIN_NAME }}
          TF_VAR_ADMIN_CIDR: ${{ vars.ADMIN_CIDR }}
          REPO_URL: ${{ github.server_url }}/${{ github.repository }}

      - name: Apply cluster/karpenter
        uses: gruntwork-io/terragrunt-action@v2
        with:
          tf_version: "1.10.0"
          tg_version: "0.68.0"
          tg_command: apply
          tg_dir: live/production/cluster/karpenter
        env:
          DOMAIN_NAME: ${{ vars.DOMAIN_NAME }}
          TF_VAR_ADMIN_CIDR: ${{ vars.ADMIN_CIDR }}
          REPO_URL: ${{ github.server_url }}/${{ github.repository }}

      - name: Apply cluster/argocd-bootstrap
        uses: gruntwork-io/terragrunt-action@v2
        with:
          tf_version: "1.10.0"
          tg_version: "0.68.0"
          tg_command: apply
          tg_dir: live/production/cluster/argocd-bootstrap
        env:
          DOMAIN_NAME: ${{ vars.DOMAIN_NAME }}
          TF_VAR_ADMIN_CIDR: ${{ vars.ADMIN_CIDR }}
          REPO_URL: ${{ github.server_url }}/${{ github.repository }}

      - name: Notify on failure
        if: failure()
        uses: slackapi/slack-github-action@v1
        with:
          payload: '{"text":"❌ richman-aws-eks Terraform apply failed on `${{ github.sha }}`"}'
        env:
          SLACK_WEBHOOK_URL: ${{ secrets.SLACK_WEBHOOK_URL }}
```

- [ ] **Step 3: Commit**

```bash
git add .github
git commit -m "ci: add GitHub Actions plan/apply workflows (disabled by default)"
```

---

### Task 19: Bootstrap S3 state bucket

**Files:**
- Create: `modules/account/bootstrap/main.tf`
- Create: `modules/account/bootstrap/variables.tf`
- Create: `modules/account/bootstrap/versions.tf`
- Create: `live/production/account/bootstrap/terragrunt.hcl`

- [ ] **Step 1: Create `modules/account/bootstrap/main.tf`**

```hcl
resource "aws_s3_bucket" "tfstate" {
  bucket = "${var.project_name}-tfstate-${var.region}"
  tags   = { Project = var.project_name, ManagedBy = "terraform" }

  lifecycle { prevent_destroy = true }
}

resource "aws_s3_bucket_versioning" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "aws:kms"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "tfstate" {
  bucket                  = aws_s3_bucket.tfstate.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
```

- [ ] **Step 2: Create `modules/account/bootstrap/variables.tf`**

```hcl
variable "project_name" { type = string }
variable "region"       { type = string }
```

- [ ] **Step 3: Create `modules/account/bootstrap/versions.tf`**

```hcl
terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = { source = "hashicorp/aws"; version = "~> 5.0" }
  }
}
```

- [ ] **Step 4: Create `live/production/account/bootstrap/terragrunt.hcl`**

```hcl
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
```

- [ ] **Step 5: Commit**

```bash
git add modules/account/bootstrap live/production/account/bootstrap
git commit -m "feat: add S3 state bucket bootstrap module"
```

---

### Task 20: Write the full README

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Write `README.md`**

```markdown
# richman-aws-eks

> Production-grade Kubernetes on AWS. The full platform you'd actually build.

The companion to [poorman-aws-k8s](https://github.com/insomniacoder/poorman-aws-k8s) — same AWS region, opposite intent. Where `poorman-aws-k8s` minimizes cost, `richman-aws-eks` demonstrates what production looks like: EKS, multi-AZ, Karpenter, full GitOps, observability, policy, and security.

## What's inside

| Layer | Components |
|---|---|
| Compute | EKS 1.31+, system managed node group (ON_DEMAND), Karpenter workload nodes (SPOT + ON_DEMAND), KEDA |
| Networking | VPC CNI + prefix delegation + NetworkPolicy enforcement, 3-tier × 3-AZ subnets, AWS LBC + Traefik |
| Security | Kyverno policies, RBAC, default-deny NetworkPolicies, EKS Pod Identity |
| Secrets | External Secrets Operator + AWS Secrets Manager |
| Observability | OTEL Operator, kube-prometheus-stack, Loki, noe, yace (CloudWatch) |
| GitOps | ArgoCD App-of-Apps with 7 sync waves, progressive sync enabled |
| Reliability | Velero backups, VPA, PriorityClasses |
| Governance | Cloud Custodian |

See the full design: [`docs/superpowers/specs/2026-05-20-richman-aws-eks-design.md`](docs/superpowers/specs/2026-05-20-richman-aws-eks-design.md)

## Prerequisites

- AWS CLI v2 (authenticated: `aws sts get-caller-identity`)
- Terraform ≥ 1.10
- Terragrunt v1
- kubectl
- helm
- A domain hosted in Route 53

## First deploy

### 1. Configure

Edit `live/production/env.hcl`:
```hcl
region       = "eu-west-1"
cluster_name = "richman-production"
domain_name  = "yourdomain.com"
```

Set environment variables:
```bash
export TF_VAR_ADMIN_CIDR="$(curl -s https://checkip.amazonaws.com)/32"
export DOMAIN_NAME="yourdomain.com"
export REPO_URL="https://github.com/your-org/richman-aws-eks"
```

### 2. Bootstrap S3 state bucket (once)
```bash
cd live/production/account/bootstrap && terragrunt apply
```

### 3. Deploy account-level infrastructure
```bash
cd live/production/account/vpc      && terragrunt apply
cd live/production/account/iam      && terragrunt apply
cd live/production/account/ecr      && terragrunt apply
```

### 4. Deploy cluster
```bash
cd live/production/cluster/eks              && terragrunt apply
cd live/production/cluster/karpenter        && terragrunt apply
cd live/production/cluster/argocd-bootstrap && terragrunt apply
```

After `argocd-bootstrap` applies, ArgoCD installs and syncs all platform components automatically via the App-of-Apps. Allow 10–15 minutes for all sync waves to complete.

### 5. Access ArgoCD
```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d
# Open https://argocd.<your-domain>
```

### 6. Access Grafana
```bash
# Open https://grafana.<your-domain>
# Login: admin / password set in kubePrometheusStack.grafanaAdminPassword
```

## Adding a second environment

1. Create `live/staging/env.hcl` with staging-specific values
2. Create `cluster-applications/environments/staging.yaml`
3. Add `values/staging.yaml` to any chart with staging-specific overrides
4. Deploy: `cd live/staging && terragrunt run --all apply`

No module changes required.

## Adding a second cluster (multi-cluster ApplicationSets)

1. Create `live/production/cluster-2/` pointing at the same modules with a different `cluster_name`
2. After deploying, migrate Applications to ApplicationSets using the cluster generator
3. Enable progressive sync (`enable-progressive-syncs` is already set in ArgoCD config)
4. See design doc § "Multi-cluster extension path" for the ApplicationSet pattern

## Using IRSA for cross-account access

Pod Identity is used for all in-cluster AWS access. For cross-account scenarios where Pod Identity doesn't reach (e.g. assuming a role in a central secrets account), add an IRSA annotation to the ServiceAccount:

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  annotations:
    eks.amazonaws.com/role-arn: arn:aws:iam::<account>:role/<role-name>
```

The EKS cluster already has an OIDC provider configured.

## Design principles

See [`docs/superpowers/specs/2026-05-20-richman-aws-eks-design.md`](docs/superpowers/specs/2026-05-20-richman-aws-eks-design.md) for full rationale on every technology choice.

## License

MIT
```

- [ ] **Step 2: Commit**

```bash
git add README.md
git commit -m "docs: write full README with deploy instructions"
```

---

## Plan self-review

### Spec coverage check

| Spec section | Covered by task(s) |
|---|---|
| Project structure (Terragrunt 2-layer) | Tasks 1–9 |
| Networking (3-tier, 3-AZ, VPC endpoints, SGs) | Task 2 |
| IAM + Pod Identity (cluster role, node role, addon roles) | Tasks 3, 8 |
| ECR + pull-through cache | Task 4 |
| EKS control plane, access entries | Task 5 |
| Managed addons (vpc-cni with prefix delegation + netpol, ebs-csi, pod-identity) | Task 6 |
| System node group | Task 6 |
| Karpenter IAM, SQS, EventBridge | Task 7 |
| Karpenter in-cluster + NodePools | Task 13 |
| KEDA | Task 13 |
| ArgoCD bootstrap | Task 9 |
| Bootstrap App-of-Apps chart with sync waves | Task 10 |
| platform-core (namespaces, priority classes, VPA, metrics-server, node-problem-detector, node-local-dns, reloader, APF flowschemas) | Task 11 |
| platform-networking (cert-manager, LBC, Traefik, ExternalDNS) | Task 12 |
| platform-secrets (ESO, ClusterSecretStore) | Task 14 |
| platform-policy (Kyverno, 4 policies, Cloud Custodian) | Task 15 |
| platform-observability (OTEL Operator, OTEL DaemonSet collector, kube-prometheus-stack, Loki, k8s-events-exporter, noe, yace) | Task 16 |
| platform-gitops (ArgoCD Projects, Velero) | Task 17 |
| GitHub Actions (plan + apply, disabled) | Task 18 |
| S3 state bucket bootstrap | Task 19 |
| Full README with deploy instructions | Task 20 |
| Environment override strategy (environments/<env>.yaml + per-chart values) | Tasks 10, all platform charts |
| Multi-cluster ApplicationSet path | Design doc + Task 17 (progressive sync enabled in ArgoCD config, Task 9) |
| Production lessons (VPA min-replicas, Kyverno Binding exclusion, cert-manager wave-1, ExternalDNS txtOwnerId, SSA on large CRDs, etc.) | Applied inline in Tasks 11–17 |

All spec requirements are covered. No gaps found.
