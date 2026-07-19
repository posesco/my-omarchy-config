variable "aws_region" {
  type        = string
  description = "AWS Region"
  default     = "eu-west-1"
}

variable "secrets" {
  description = "Map of secrets to store in SSM Parameter Store"
  type = map(object({
    value       = string
    description = string
    type        = string
  }))
  sensitive = true
}
