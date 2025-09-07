output "s3_bucket"       { value = aws_s3_bucket.reports.bucket }
output "dynamodb_table" { value = aws_dynamodb_table.costops.name }
output "sns_topic_arn"  { value = aws_sns_topic.summaries.arn }
output "dashboard"      { value = aws_cloudwatch_dashboard.main.dashboard_name }
output "scanner_arn"    { value = aws_lambda_function.scanner.arn }
output "action_arn"     { value = aws_lambda_function.action.arn }
output "ai_arn"         { value = aws_lambda_function.ai.arn }