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
