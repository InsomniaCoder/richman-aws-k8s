data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

locals {
  # EKS writes control plane logs to this log group (created by the eks module)
  log_group_name = "/aws/eks/${var.cluster_name}/cluster"
  function_name  = "${var.cluster_name}-cp-log-forwarder"
}

# ── IAM ───────────────────────────────────────────────────────────────────────

resource "aws_iam_role" "lambda" {
  name = local.function_name

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy" "lambda_logs" {
  name = "cloudwatch-logs"
  role = aws_iam_role.lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "${aws_cloudwatch_log_group.lambda.arn}:*"
      },
      {
        # Read the control plane log group (needed to set up subscription)
        Effect   = "Allow"
        Action   = ["logs:DescribeLogGroups", "logs:DescribeLogStreams"]
        Resource = "arn:aws:logs:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:log-group:${local.log_group_name}:*"
      }
    ]
  })
}

resource "aws_iam_role_policy" "lambda_ssm" {
  name = "ssm-grafana-creds"
  role = aws_iam_role.lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["ssm:GetParameter", "ssm:GetParameters"]
      Resource = [
        "arn:aws:ssm:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:parameter/${var.project_name}/${var.environment}/grafana-cloud/*"
      ]
    }]
  })
}

# ── Lambda function ───────────────────────────────────────────────────────────

resource "aws_cloudwatch_log_group" "lambda" {
  name              = "/aws/lambda/${local.function_name}"
  retention_in_days = 14
  tags              = var.tags
}

resource "aws_lambda_function" "forwarder" {
  function_name = local.function_name
  role          = aws_iam_role.lambda.arn

  # Public lambda-promtail image published by Grafana Labs.
  # Pin to a specific digest in production for reproducibility.
  # Latest releases: https://github.com/grafana/loki/releases
  image_uri    = var.lambda_promtail_image
  package_type = "Image"

  timeout     = 60
  memory_size = 128

  environment {
    variables = {
      WRITE_ADDRESS            = var.loki_write_address
      USERNAME                 = var.loki_username
      PASSWORD                 = var.loki_password
      EXTRA_LABELS             = "cluster,${var.cluster_name},environment,${var.environment}"
      OMIT_EXTRA_LABELS_PREFIX = "true"
      KEEP_STREAM              = "true"
      PRINT_LOG_LINE           = "false"
      BATCH_SIZE               = "131072"  # 128 KiB — matches Grafana Cloud Loki push limit
    }
  }

  depends_on = [aws_cloudwatch_log_group.lambda]

  tags = var.tags
}

resource "aws_lambda_function_event_invoke_config" "forwarder" {
  function_name          = aws_lambda_function.forwarder.function_name
  maximum_retry_attempts = 2
}

# ── CloudWatch → Lambda subscription ─────────────────────────────────────────

resource "aws_lambda_permission" "allow_cloudwatch" {
  statement_id  = "allow-cloudwatch-${var.cluster_name}"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.forwarder.function_name
  principal     = "logs.${data.aws_region.current.name}.amazonaws.com"
  source_arn    = "arn:aws:logs:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:log-group:${local.log_group_name}:*"
}

resource "aws_cloudwatch_log_subscription_filter" "control_plane" {
  name            = "${var.cluster_name}-to-grafana-cloud"
  log_group_name  = local.log_group_name
  destination_arn = aws_lambda_function.forwarder.arn
  filter_pattern  = ""   # forward all events

  depends_on = [aws_lambda_permission.allow_cloudwatch]
}
