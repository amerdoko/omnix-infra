terraform {
  required_providers {
    azurerm = { source = "hashicorp/azurerm", version = "~> 4.0" }
  }
}

variable "name_prefix" { type = string }
variable "env" { type = string }
variable "location" { type = string }
variable "resource_group_name" { type = string }
variable "tenant_id" { type = string }
variable "pe_subnet_id" { type = string }
variable "private_dns_zone_id" { type = string }
variable "log_analytics_workspace_id" {
  type    = string
  default = null
}
variable "public_network_access_enabled" {
  type    = bool
  default = false
}
variable "network_acls_default_action" {
  type    = string
  default = "Deny"
}
variable "network_acls_ip_rules" {
  type    = list(string)
  default = []
}
variable "tags" {
  type    = map(string)
  default = {}
}

resource "random_string" "suffix" {
  length  = 4
  upper   = false
  special = false
  numeric = true
}

resource "azurerm_key_vault" "this" {
  name                          = "kv-${var.name_prefix}-${var.env}-${random_string.suffix.result}"
  location                      = var.location
  resource_group_name           = var.resource_group_name
  tenant_id                     = var.tenant_id
  sku_name                      = "standard"
  rbac_authorization_enabled    = true
  soft_delete_retention_days    = 7
  purge_protection_enabled      = true
  public_network_access_enabled = var.public_network_access_enabled
  tags                          = var.tags

  network_acls {
    default_action = var.network_acls_default_action
    bypass         = "AzureServices"
    ip_rules       = var.network_acls_ip_rules
  }
}

module "pe" {
  source              = "../private-endpoint"
  name                = "kv-${var.name_prefix}-${var.env}"
  location            = var.location
  resource_group_name = var.resource_group_name
  subnet_id           = var.pe_subnet_id
  target_resource_id  = azurerm_key_vault.this.id
  subresource_names   = ["vault"]
  private_dns_zone_id = var.private_dns_zone_id
  tags                = var.tags
}

resource "azurerm_monitor_diagnostic_setting" "this" {
  name                       = "diag"
  target_resource_id         = azurerm_key_vault.this.id
  log_analytics_workspace_id = var.log_analytics_workspace_id

  enabled_log { category = "AuditEvent" }
  enabled_log { category = "AzurePolicyEvaluationDetails" }
  enabled_metric { category = "AllMetrics" }
}

output "id" { value = azurerm_key_vault.this.id }
output "name" { value = azurerm_key_vault.this.name }
output "vault_uri" { value = azurerm_key_vault.this.vault_uri }
