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
  event_pattern = jsonencode({ source = each.value.source, "detail-type" = each.value["detail-type"] })
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
  tags  = local.common_tags
}

resource "aws_ssm_parameter" "interruption_queue_name" {
  name  = "/${var.project_name}/${var.environment}/karpenter/interruption-queue-name"
  type  = "String"
  value = aws_sqs_queue.interruption.name
  tags  = local.common_tags
}
