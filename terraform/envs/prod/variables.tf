variable "aws_profile" {
  description = "AWS CLI profile to use"
  type        = string
  default     = "mullet-dev"
}

variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-west-2"
}

variable "project_name" {
  description = "Project slug"
  type        = string
  default     = "mullet-product-agent"
}

variable "environment" {
  description = "Environment name"
  type        = string
  default     = "prod"
}

variable "availability_zone" {
  description = "Lightsail AZ"
  type        = string
  default     = "us-west-2a"
}

variable "lightsail_blueprint_id" {
  description = "Lightsail OS blueprint"
  type        = string
  default     = "ubuntu_24_04"
}

variable "lightsail_bundle_id" {
  description = "Lightsail instance bundle (small_3_0 provides 2GB RAM for stable OpenClaw runtime)"
  type        = string
  default     = "small_3_0"
}

variable "ssh_public_key_path" {
  description = "Absolute path to local SSH public key"
  type        = string
}

variable "allowed_ssh_cidrs" {
  description = "CIDRs allowed to SSH"
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "allowed_http_cidrs" {
  description = "CIDRs allowed for HTTP/HTTPS"
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "snapshot_time_utc" {
  description = "Daily snapshot time in UTC (HH:MM)"
  type        = string
  default     = "07:00"
}

variable "openclaw_repo_url" {
  description = "Repository URL for openclaw source"
  type        = string
  default     = "https://github.com/openclaw/openclaw.git"
}

variable "openclaw_repo_ref" {
  description = "Git ref to deploy"
  type        = string
  default     = "main"
}

variable "openclaw_image" {
  description = "Prebuilt OpenClaw image pinned for production stability"
  type        = string
  default     = "ghcr.io/openclaw/openclaw:2026.2.26"
}

variable "deploy_user" {
  description = "Linux user for operations"
  type        = string
  default     = "ubuntu"
}

variable "monthly_budget_limit_usd" {
  description = "Monthly AWS budget threshold"
  type        = number
  default     = 10
}

variable "budget_alert_emails" {
  description = "Email addresses for budget alerts"
  type        = list(string)
  default     = []
}

variable "attach_operator_user" {
  description = "Attach existing IAM user to project operator group"
  type        = bool
  default     = false
}

variable "operator_iam_user" {
  description = "Existing IAM user to attach to project operator group"
  type        = string
  default     = "mullet-dev"
}
