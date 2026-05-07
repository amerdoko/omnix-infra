terraform {
  required_providers {
    azurerm = { source = "hashicorp/azurerm", version = "~> 4.0" }
  }
}

# Creates all standard privatelink DNS zones and links them to a list of VNets.
# Run once in the shared layer. Env layers later add VNet links via separate
# azurerm_private_dns_zone_virtual_network_link resources for their own VNets.

variable "resource_group_name" { type = string }
variable "tags" {
  type    = map(string)
  default = {}
}

locals {
  zones = [
    "privatelink.azurecr.io",
    "privatelink.vaultcore.azure.net",
    "privatelink.database.windows.net",
    "privatelink.blob.core.windows.net",
    "privatelink.file.core.windows.net",
    # AKS API server zone is region-specific (privatelink.<region>.azmk8s.io).
    # That's created in the AKS module's region using a separate resource.
  ]
}

resource "azurerm_private_dns_zone" "this" {
  for_each            = toset(local.zones)
  name                = each.key
  resource_group_name = var.resource_group_name
  tags                = var.tags
}

output "zone_ids" {
  value = { for z, r in azurerm_private_dns_zone.this : z => r.id }
}
output "zone_names" {
  value = { for z, r in azurerm_private_dns_zone.this : z => r.name }
}
