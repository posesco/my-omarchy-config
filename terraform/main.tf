resource "aws_ssm_parameter" "omarchy" {
  for_each = var.secrets

  # Las claves del mapa se mapearán bajo el prefijo /omarchy/
  name        = "/omarchy/${each.key}"
  description = each.value.description
  type        = each.value.type
  value       = each.value.value

  tags = {
    Project   = "omarchy-config"
    ManagedBy = "terraform"
  }
}
