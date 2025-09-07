locals {
  bucket_prefixes = {
    for env in var.environments :
    env => {
      reports      = "${env}/reports/"
      ai_summaries = "${env}/ai_summaries/"
    }
  }
}


resource "aws_s3_bucket" "reports" { bucket = var.s3_bucket_name }
resource "aws_s3_bucket_versioning" "reports" {
  bucket = aws_s3_bucket.reports.id

  versioning_configuration {
    status = "Enabled"
  }
}
resource "aws_s3_bucket_server_side_encryption_configuration" "reports" {
  bucket = aws_s3_bucket.reports.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}
resource "aws_s3_bucket_public_access_block" "reports" {
  bucket                  = aws_s3_bucket.reports.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}


resource "aws_dynamodb_table" "costops" {
  name         = var.dynamodb_table_name
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "pk"
  range_key    = "sk"
  attribute {
    name = "pk"
    type = "S"
  }
  attribute {
    name = "sk"
    type = "S"
  }
  attribute {
    name = "gsi1pk"
    type = "S"
  }
  attribute {
    name = "gsi1sk"
    type = "S"
  }
  global_secondary_index {
    name            = "gsi1"
    hash_key        = "gsi1pk"
    range_key       = "gsi1sk"
    projection_type = "ALL"
  }
  ttl {
    attribute_name = "ttl"
    enabled        = true
  }
}

resource "aws_sns_topic" "summaries" { name = var.sns_topic_name }

resource "aws_ecr_repository" "scanner" {
  name = "${var.ecr_repo_prefix}-scanner"

  image_scanning_configuration {
    scan_on_push = true
  }
}
resource "aws_ecr_repository" "action" {
  name = "${var.ecr_repo_prefix}-action"

  image_scanning_configuration {
    scan_on_push = true
  }
}
resource "aws_ecr_repository" "ai" {
  name = "${var.ecr_repo_prefix}-ai"

  image_scanning_configuration {
    scan_on_push = true
  }
}

data "aws_iam_policy_document" "assume_lambda" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "lambda_logs" {
  statement {
    actions   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["*"]
  }
}
resource "aws_iam_policy" "lambda_logs" {
  name   = "LevelUpLambdaLogs"
  policy = data.aws_iam_policy_document.lambda_logs.json
}

data "aws_iam_policy_document" "scanner" {
  statement {
    actions   = ["ec2:Describe*"]
    resources = ["*"]
  }
  statement {
    actions   = ["cloudwatch:GetMetricData", "cloudwatch:GetMetricStatistics", "cloudwatch:ListMetrics"]
    resources = ["*"]
  }
  statement {
    actions   = ["s3:ListAllMyBuckets", "s3:ListBucket"]
    resources = ["*"]
  }
}
resource "aws_iam_policy" "scanner" {
  name   = "LevelUpScannerPolicy"
  policy = data.aws_iam_policy_document.scanner.json
}
resource "aws_iam_role" "scanner" {
  name               = "LevelUpScannerRole"
  assume_role_policy = data.aws_iam_policy_document.assume_lambda.json
}
resource "aws_iam_role_policy_attachment" "scanner_logs" {
  role       = aws_iam_role.scanner.name
  policy_arn = aws_iam_policy.lambda_logs.arn
}
resource "aws_iam_role_policy_attachment" "scanner_perm" {
  role       = aws_iam_role.scanner.name
  policy_arn = aws_iam_policy.scanner.arn
}

data "aws_iam_policy_document" "action" {
  statement {
    actions   = ["ec2:Describe*", "ec2:CreateTags", "ec2:StopInstances"]
    resources = ["*"]
  }
  statement {
    actions   = ["s3:GetBucketTagging", "s3:PutBucketTagging", "s3:ListBucket"]
    resources = ["*"]
  }
  statement {
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.reports.arn}/*"]
  }
  statement {
    actions   = ["dynamodb:PutItem", "dynamodb:UpdateItem"]
    resources = [aws_dynamodb_table.costops.arn]
  }
}
resource "aws_iam_policy" "action" {
  name   = "LevelUpActionPolicy"
  policy = data.aws_iam_policy_document.action.json
}
resource "aws_iam_role" "action" {
  name               = "LevelUpActionRole"
  assume_role_policy = data.aws_iam_policy_document.assume_lambda.json
}
resource "aws_iam_role_policy_attachment" "action_logs" {
  role       = aws_iam_role.action.name
  policy_arn = aws_iam_policy.lambda_logs.arn
}
resource "aws_iam_role_policy_attachment" "action_perm" {
  role       = aws_iam_role.action.name
  policy_arn = aws_iam_policy.action.arn
}

data "aws_iam_policy_document" "ai" {
  statement {
    actions   = ["dynamodb:Query", "dynamodb:Scan"]
    resources = [aws_dynamodb_table.costops.arn, "${aws_dynamodb_table.costops.arn}/index/*"]
  }
  statement {
    actions   = ["s3:GetObject", "s3:ListBucket", "s3:PutObject"]
    resources = [aws_s3_bucket.reports.arn, "${aws_s3_bucket.reports.arn}/*"]
  }
  statement {
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.summaries.arn]
  }
  statement {
    actions   = ["bedrock:InvokeModel"]
    resources = ["*"]
  }
}
resource "aws_iam_policy" "ai" {
  name   = "LevelUpAIPolicy"
  policy = data.aws_iam_policy_document.ai.json
}
resource "aws_iam_role" "ai" {
  name               = "LevelUpAIRole"
  assume_role_policy = data.aws_iam_policy_document.assume_lambda.json
}
resource "aws_iam_role_policy_attachment" "ai_logs" {
  role       = aws_iam_role.ai.name
  policy_arn = aws_iam_policy.lambda_logs.arn
}
resource "aws_iam_role_policy_attachment" "ai_perm" {
  role       = aws_iam_role.ai.name
  policy_arn = aws_iam_policy.ai.arn
}

locals {
  scanner_image = "${var.aws_account_id}.dkr.ecr.${var.aws_region}.amazonaws.com/${var.ecr_repo_prefix}-scanner:${var.scanner_image_tag}"
  action_image  = "${var.aws_account_id}.dkr.ecr.${var.aws_region}.amazonaws.com/${var.ecr_repo_prefix}-action:${var.action_image_tag}"
  ai_image      = "${var.aws_account_id}.dkr.ecr.${var.aws_region}.amazonaws.com/${var.ecr_repo_prefix}-ai:${var.ai_image_tag}"
}

resource "aws_lambda_function" "scanner" {
  function_name = "levelup-scanner"
  role          = aws_iam_role.scanner.arn
  package_type  = "Image"
  image_uri     = local.scanner_image
  timeout       = 900
  environment { variables = {
    PROJECT   = var.project, ENVIRONMENTS = join(",", var.environments),
    S3_BUCKET = aws_s3_bucket.reports.bucket, DDB_TABLE = aws_dynamodb_table.costops.name,
    METRIC_NS = "LevelUp/CostOps", CPU_IDLE_THRESHOLD = "5", CPU_IDLE_DAYS = "7", S3_EMPTY_DAYS = "30"
  } }
}

resource "aws_lambda_function" "action" {
  function_name = "levelup-action"
  role          = aws_iam_role.action.arn
  package_type  = "Image"
  image_uri     = local.action_image
  timeout       = 900
  environment { variables = {
    PROJECT   = var.project, S3_BUCKET = aws_s3_bucket.reports.bucket, DDB_TABLE = aws_dynamodb_table.costops.name,
    METRIC_NS = "LevelUp/CostOps", ENFORCE_SAFE_TAG = var.enforce_safe_tag ? "true" : "false"
  } }
}

resource "aws_lambda_function" "ai" {
  function_name = "levelup-ai-insights"
  role          = aws_iam_role.ai.arn
  package_type  = "Image"
  image_uri     = local.ai_image
  timeout       = 120
  environment { variables = {
    PROJECT       = var.project, S3_BUCKET = aws_s3_bucket.reports.bucket, DDB_TABLE = aws_dynamodb_table.costops.name,
    SNS_TOPIC_ARN = aws_sns_topic.summaries.arn, MODEL_ID = var.bedrock_model_id,
    SUMMARY_TOP_N = tostring(var.summary_top_n), SUMMARY_RECENCY_DAYS = tostring(var.summary_recency_days)
  } }
}

resource "aws_cloudwatch_log_group" "scanner" {
  name              = "/aws/lambda/${aws_lambda_function.scanner.function_name}"
  retention_in_days = 14
}
resource "aws_cloudwatch_log_group" "action" {
  name              = "/aws/lambda/${aws_lambda_function.action.function_name}"
  retention_in_days = 14
}
resource "aws_cloudwatch_log_group" "ai" {
  name              = "/aws/lambda/${aws_lambda_function.ai.function_name}"
  retention_in_days = 14
}

resource "aws_cloudwatch_event_rule" "scan" {
  name                = "levelup-scan"
  schedule_expression = var.scanner_cron
}
resource "aws_cloudwatch_event_rule" "act" {
  name                = "levelup-act"
  schedule_expression = var.action_cron
}
resource "aws_cloudwatch_event_target" "scan_target" {
  rule      = aws_cloudwatch_event_rule.scan.name
  target_id = "scanner"
  arn       = aws_lambda_function.scanner.arn
}
resource "aws_cloudwatch_event_target" "act_target" {
  rule      = aws_cloudwatch_event_rule.act.name
  target_id = "action"
  arn       = aws_lambda_function.action.arn
}
resource "aws_lambda_permission" "allow_events_scan" {
  statement_id  = "AllowExecutionFromEventBridgeScan"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.scanner.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.scan.arn
}
resource "aws_lambda_permission" "allow_events_act" {
  statement_id  = "AllowExecutionFromEventBridgeAct"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.action.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.act.arn
}

resource "aws_cloudwatch_dashboard" "main" {
  dashboard_name = "levelup-costops-dashboard"
  dashboard_body = jsonencode({
    widgets = [
      { "type" : "metric", "x" : 0, "y" : 0, "width" : 12, "height" : 6,
        "properties" : { "title" : "Idle EC2 Count", "metrics" : [
          ["LevelUp/CostOps", "IdleEC2Count", "Env", "staging"],
          [".", ".", ".", "prod"]
      ], "stat" : "Maximum", "view" : "timeSeries", "region" : var.aws_region } },
      { "type" : "metric", "x" : 12, "y" : 0, "width" : 12, "height" : 6,
        "properties" : { "title" : "Estimated Monthly Savings (USD)", "metrics" : [
          ["LevelUp/CostOps", "EstimatedMonthlySavings", "Env", "staging"],
          [".", ".", ".", "prod"]
      ], "stat" : "Average", "view" : "timeSeries", "region" : var.aws_region } }
    ]
  })
}

resource "aws_cloudwatch_metric_alarm" "too_many_idle" {
  alarm_name          = "levelup-idle-ec2-threshold"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "IdleEC2Count"
  namespace           = "LevelUp/CostOps"
  period              = 300
  statistic           = "Maximum"
  threshold           = 5
  alarm_description   = "More than 5 idle EC2 detected in a single scan"
  dimensions          = { Env = "prod" }
  alarm_actions       = [aws_sns_topic.summaries.arn]
}
