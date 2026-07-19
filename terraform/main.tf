resource "aws_ssm_parameter" "omarchy" {
  for_each = var.secrets

  # Map keys are mapped under the /omarchy/ prefix
  name        = "/omarchy/${each.key}"
  description = each.value.description
  type        = each.value.type
  value       = each.value.value

  tags = {
    Project   = "omarchy-config"
    ManagedBy = "terraform"
  }
}
