variable "aws_profile" {
  description = "AWS CLI profile to use"
  type        = string
  default     = "mullet-dev"
}

variable "aws_region" {
  description = "AWS region for backend resources"
  type        = string
  default     = "us-west-2"
}

variable "state_bucket_name" {
  description = "Globally unique S3 bucket name for Terraform state"
  type        = string
}

variable "lock_table_name" {
  description = "DynamoDB table name for Terraform state locking"
  type        = string
  default     = "mullet-product-agent-tf-locks"
}

variable "tags" {
  description = "Resource tags"
  type        = map(string)
  default = {
    Project     = "mullet-product-agent"
    Environment = "shared"
    ManagedBy   = "terraform"
  }
}
