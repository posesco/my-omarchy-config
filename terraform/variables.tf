variable "aws_region" {
  type        = string
  description = "AWS Region"
  default     = "eu-west-1"
}

variable "secrets" {
  description = "Map of secrets to be stored in SSM Parameter Store for Omarchy"
  type = map(object({
    value       = string
    description = string
    type        = string
  }))
  sensitive = true
}
