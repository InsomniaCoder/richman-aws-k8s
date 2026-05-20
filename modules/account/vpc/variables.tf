variable "project_name"        { type = string }
variable "environment"         { type = string }
variable "vpc_cidr"            { type = string; default = "10.0.0.0/16" }
variable "availability_zones"  { type = list(string) }
variable "single_nat_gateway"  { type = bool; default = false; description = "Use one NAT GW instead of one-per-AZ. Set true for dev/cost savings." }
variable "create_vpc_endpoints" { type = bool; default = true; description = "Create interface VPC endpoints (ECR, Secrets Manager, SSM, STS, EC2). ~$7/mo each per AZ." }
variable "tags"                { type = map(string); default = {} }
