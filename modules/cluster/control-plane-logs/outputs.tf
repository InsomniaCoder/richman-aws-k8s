output "lambda_arn" {
  value = aws_lambda_function.forwarder.arn
}

output "lambda_function_name" {
  value = aws_lambda_function.forwarder.function_name
}
