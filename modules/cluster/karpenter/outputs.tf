output "controller_role_arn"     { value = aws_iam_role.karpenter_controller.arn }
output "interruption_queue_name" { value = aws_sqs_queue.interruption.name }
