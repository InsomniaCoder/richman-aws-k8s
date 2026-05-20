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
