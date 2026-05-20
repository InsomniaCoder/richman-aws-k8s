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
