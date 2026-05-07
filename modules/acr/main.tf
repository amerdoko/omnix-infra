terraform {
  required_providers {
    azurerm = { source = "hashicorp/azurerm", version = "~> 4.0" }
    random  = { source = "hashicorp/random", version = "~> 3.6" }
  }
}

variable "name_prefix" { type = string }
variable "location" { type = string }
variable "geo_replica_location" { type = string }
variable "resource_group_name" { type = string }
variable "private_dns_zone_id" { type = string }
variable "pe_subnet_id" { type = string } # shared pe subnet
variable "tags" {
  type    = map(string)
  default = {}
}

resource "random_string" "suffix" {
  length  = 6
  upper   = false
  special = false
  numeric = true
}

resource "azurerm_container_registry" "this" {
  name                          = "acr${var.name_prefix}${random_string.suffix.result}"
  resource_group_name           = var.resource_group_name
  location                      = var.location
  sku                           = "Premium"
  admin_enabled                 = false
  public_network_access_enabled = false
  zone_redundancy_enabled       = false
  tags                          = var.tags

  georeplications {
    location                = var.geo_replica_location
    zone_redundancy_enabled = false
    tags                    = var.tags
  }

  trust_policy_enabled = true
}

module "pe" {
  source              = "../private-endpoint"
  name                = "acr-${var.name_prefix}"
  location            = var.location
  resource_group_name = var.resource_group_name
  subnet_id           = var.pe_subnet_id
  target_resource_id  = azurerm_container_registry.this.id
  subresource_names   = ["registry"]
  private_dns_zone_id = var.private_dns_zone_id
  tags                = var.tags
}

output "id" { value = azurerm_container_registry.this.id }
output "name" { value = azurerm_container_registry.this.name }
output "login_server" { value = azurerm_container_registry.this.login_server }
