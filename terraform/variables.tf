variable "project"         { type = string }
variable "aws_region"      { type = string }
variable "aws_account_id"  { type = string }
variable "environments" {
  type    = list(string)
  default = ["staging", "prod"]
}
variable "s3_bucket_name"  { type = string }
variable "dynamodb_table_name" {
  type    = string
  default = "levelup-costops"
}
variable "sns_topic_name" {
  type    = string
  default = "levelup-costops-summaries"
}
variable "scanner_cron" {
  type    = string
  default = "cron(0 0 * * ? *)"
}
variable "action_cron" {
  type    = string
  default = "cron(30 0 * * ? *)"
}
variable "ecr_repo_prefix" {
  type    = string
  default = "levelup-costops"
}
variable "scanner_image_tag" {
  type    = string
  default = "bootstrap"
}
variable "action_image_tag" {
  type    = string
  default = "bootstrap"
}
variable "ai_image_tag" {
  type    = string
  default = "bootstrap"
}
variable "bedrock_model_id" {
  type    = string
  default = "anthropic.claude-3-haiku-20240307-v1:0"
}
variable "summary_top_n" {
  type    = number
  default = 5
}
variable "summary_recency_days" {
  type    = number
  default = 7
}
variable "enforce_safe_tag" {
  type    = bool
  default = true
}
