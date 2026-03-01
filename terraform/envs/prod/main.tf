resource "aws_lightsail_key_pair" "paige" {
  name       = "${local.name_prefix}-ssh"
  public_key = file(var.ssh_public_key_path)
}

resource "aws_lightsail_instance" "paige" {
  name              = "${local.name_prefix}-instance"
  availability_zone = var.availability_zone
  blueprint_id      = var.lightsail_blueprint_id
  bundle_id         = var.lightsail_bundle_id
  key_pair_name     = aws_lightsail_key_pair.paige.name

  user_data = templatefile("${path.module}/templates/cloud-init.sh.tftpl", {
    deploy_user       = var.deploy_user
    openclaw_repo_url = var.openclaw_repo_url
    openclaw_repo_ref = var.openclaw_repo_ref
    openclaw_image    = var.openclaw_image
  })

  add_on {
    type          = "AutoSnapshot"
    status        = "Enabled"
    snapshot_time = var.snapshot_time_utc
  }

  tags = local.common_tags
}

resource "aws_lightsail_static_ip" "paige" {
  name = "${local.name_prefix}-ip"
}

resource "aws_lightsail_static_ip_attachment" "paige" {
  static_ip_name = aws_lightsail_static_ip.paige.name
  instance_name  = aws_lightsail_instance.paige.name

  lifecycle {
    replace_triggered_by = [aws_lightsail_instance.paige.id]
  }
}

resource "aws_lightsail_instance_public_ports" "paige" {
  instance_name = aws_lightsail_instance.paige.name

  port_info {
    from_port = 22
    to_port   = 22
    protocol  = "tcp"
    cidrs     = var.allowed_ssh_cidrs
  }

  port_info {
    from_port = 80
    to_port   = 80
    protocol  = "tcp"
    cidrs     = var.allowed_http_cidrs
  }

  port_info {
    from_port = 443
    to_port   = 443
    protocol  = "tcp"
    cidrs     = var.allowed_http_cidrs
  }
}

resource "aws_budgets_budget" "monthly" {
  name              = "${local.name_prefix}-monthly-cost"
  budget_type       = "COST"
  limit_amount      = tostring(var.monthly_budget_limit_usd)
  limit_unit        = "USD"
  time_unit         = "MONTHLY"
  time_period_start = "2026-01-01_00:00"

  dynamic "notification" {
    for_each = length(var.budget_alert_emails) > 0 ? [1] : []

    content {
      comparison_operator        = "GREATER_THAN"
      threshold                  = 80
      threshold_type             = "PERCENTAGE"
      notification_type          = "ACTUAL"
      subscriber_email_addresses = var.budget_alert_emails
    }
  }

  tags = local.common_tags
}

resource "aws_iam_group" "operators" {
  name = "${local.name_prefix}-operators"
}

data "aws_iam_policy_document" "operators" {
  statement {
    sid    = "LightsailAndBudgetOps"
    effect = "Allow"

    actions = [
      "lightsail:*",
      "budgets:*",
      "ce:GetCostAndUsage",
      "ce:GetDimensionValues",
      "ce:GetCostForecast",
      "cloudwatch:GetMetricData",
      "cloudwatch:ListMetrics",
      "cloudwatch:DescribeAlarms",
      "s3:ListAllMyBuckets",
      "s3:GetBucketLocation",
      "s3:ListBucket",
      "s3:GetObject",
      "s3:PutObject",
      "dynamodb:DescribeTable",
      "dynamodb:GetItem",
      "dynamodb:PutItem",
      "dynamodb:DeleteItem",
      "dynamodb:UpdateItem"
    ]

    resources = ["*"]
  }
}

resource "aws_iam_group_policy" "operators" {
  name   = "${local.name_prefix}-operators-policy"
  group  = aws_iam_group.operators.name
  policy = data.aws_iam_policy_document.operators.json
}

resource "aws_iam_user_group_membership" "operator" {
  count = var.attach_operator_user ? 1 : 0

  user   = var.operator_iam_user
  groups = [aws_iam_group.operators.name]
}
