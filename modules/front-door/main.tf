terraform {
  required_providers {
    azurerm = { source = "hashicorp/azurerm", version = "~> 4.0" }
  }
}

variable "name_prefix" { type = string }
variable "resource_group_name" { type = string }
variable "primary_origin_host" {
  type        = string
  description = "FQDN or public IP of primary (prod) origin. Use 'placeholder.invalid' on first apply, then update with the prod LB IP."
  default     = "placeholder.invalid"
}
variable "dr_origin_host" {
  type        = string
  description = "FQDN or public IP of DR origin."
  default     = "placeholder.invalid"
}
variable "origin_port_http" {
  type    = number
  default = 80
}
variable "origin_port_https" {
  type    = number
  default = 443
}
variable "use_https_origin" {
  type    = bool
  default = false
}
variable "tags" {
  type    = map(string)
  default = {}
}

resource "azurerm_cdn_frontdoor_profile" "this" {
  name                = "afd-${var.name_prefix}"
  resource_group_name = var.resource_group_name
  sku_name            = "Standard_AzureFrontDoor"
  tags                = var.tags
}

resource "azurerm_cdn_frontdoor_endpoint" "this" {
  name                     = "ep-${var.name_prefix}"
  cdn_frontdoor_profile_id = azurerm_cdn_frontdoor_profile.this.id
  enabled                  = true
  tags                     = var.tags
}

resource "azurerm_cdn_frontdoor_origin_group" "this" {
  name                     = "og-${var.name_prefix}-mendix"
  cdn_frontdoor_profile_id = azurerm_cdn_frontdoor_profile.this.id
  session_affinity_enabled = false

  load_balancing {
    sample_size                        = 4
    successful_samples_required        = 2
    additional_latency_in_milliseconds = 50
  }

  health_probe {
    path                = "/"
    request_type        = "HEAD"
    protocol            = var.use_https_origin ? "Https" : "Http"
    interval_in_seconds = 30
  }
}

resource "azurerm_cdn_frontdoor_origin" "primary" {
  name                          = "origin-prod"
  cdn_frontdoor_origin_group_id = azurerm_cdn_frontdoor_origin_group.this.id

  enabled                        = true
  certificate_name_check_enabled = false
  host_name                      = var.primary_origin_host
  http_port                      = var.origin_port_http
  https_port                     = var.origin_port_https
  origin_host_header             = var.primary_origin_host
  priority                       = 1
  weight                         = 1000
}

resource "azurerm_cdn_frontdoor_origin" "dr" {
  name                          = "origin-dr"
  cdn_frontdoor_origin_group_id = azurerm_cdn_frontdoor_origin_group.this.id

  enabled                        = true
  certificate_name_check_enabled = false
  host_name                      = var.dr_origin_host
  http_port                      = var.origin_port_http
  https_port                     = var.origin_port_https
  origin_host_header             = var.dr_origin_host
  priority                       = 2
  weight                         = 1000
}

resource "azurerm_cdn_frontdoor_route" "this" {
  name                          = "route-mendix"
  cdn_frontdoor_endpoint_id     = azurerm_cdn_frontdoor_endpoint.this.id
  cdn_frontdoor_origin_group_id = azurerm_cdn_frontdoor_origin_group.this.id
  cdn_frontdoor_origin_ids = [
    azurerm_cdn_frontdoor_origin.primary.id,
    azurerm_cdn_frontdoor_origin.dr.id,
  ]

  enabled                = true
  forwarding_protocol    = var.use_https_origin ? "HttpsOnly" : "HttpOnly"
  https_redirect_enabled = true
  patterns_to_match      = ["/*"]
  supported_protocols    = ["Http", "Https"]
  link_to_default_domain = true
}

output "endpoint_hostname" { value = azurerm_cdn_frontdoor_endpoint.this.host_name }
output "endpoint_url" { value = "https://${azurerm_cdn_frontdoor_endpoint.this.host_name}/" }
output "profile_name" { value = azurerm_cdn_frontdoor_profile.this.name }
output "endpoint_name" { value = azurerm_cdn_frontdoor_endpoint.this.name }
output "origin_group_name" { value = azurerm_cdn_frontdoor_origin_group.this.name }
output "primary_origin_name" { value = azurerm_cdn_frontdoor_origin.primary.name }
output "dr_origin_name" { value = azurerm_cdn_frontdoor_origin.dr.name }
