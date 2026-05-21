variable "project_name"        { type = string }
variable "environment"         { type = string }
variable "vpc_cidr"            { type = string; default = "10.0.0.0/16" }
# RFC 6598 address space for pod subnets. Attached as a secondary CIDR block on the VPC.
# 100.64.0.0/10 = 4M IPs split across 3 AZs as /12s (1M IPs each).
# In a multi-cluster account, allocate a sub-range per cluster (e.g. cluster-1: 100.64.0.0/12,
# cluster-2: 100.80.0.0/12, cluster-3: 100.96.0.0/12) to avoid ENIConfig subnet overlap.
variable "pod_cidr"            { type = string; default = "100.64.0.0/10" }
variable "availability_zones"  { type = list(string) }
variable "single_nat_gateway"  { type = bool; default = false; description = "Use one NAT GW instead of one-per-AZ. Set true for dev/cost savings." }
variable "create_vpc_endpoints" { type = bool; default = true; description = "Create interface VPC endpoints (ECR, Secrets Manager, SSM, STS, EC2). ~$7/mo each per AZ." }
variable "tags"                { type = map(string); default = {} }
