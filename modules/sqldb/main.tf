terraform {
  required_providers {
    azurerm = { source = "hashicorp/azurerm", version = "~> 4.0" }
    random  = { source = "hashicorp/random", version = "~> 3.6" }
  }
}

variable "name_prefix" { type = string }
variable "env" { type = string }
variable "location" { type = string }            # SQL server region
variable "pe_location" {                          # private endpoint region (where snet-pe lives)
  type    = string
  default = null
}
variable "resource_group_name" { type = string }
variable "tenant_id" { type = string }
variable "entra_admin_login" { type = string }
variable "entra_admin_object_id" { type = string }
variable "pe_subnet_id" { type = string }
variable "private_dns_zone_id" { type = string }
variable "sku_name" {
  type    = string
  default = "Basic"
} # Basic / S0 / S1 / S2 / GP_S_Gen5_2 etc.
variable "max_size_gb" {
  type    = number
  default = 2
}
variable "tags" {
  type    = map(string)
  default = {}
}

resource "random_string" "server_suffix" {
  length  = 4
  upper   = false
  special = false
  numeric = true
}

resource "random_password" "sql_admin" {
  length           = 24
  special          = true
  min_lower        = 2
  min_upper        = 2
  min_numeric      = 2
  min_special      = 2
  override_special = "!@#$%^&*()-_=+[]{}"
}

resource "azurerm_mssql_server" "this" {
  name                          = "sql-${var.name_prefix}-${var.env}-${random_string.server_suffix.result}"
  location                      = var.location
  resource_group_name           = var.resource_group_name
  version                       = "12.0"
  administrator_login           = "sqladmin"
  administrator_login_password  = random_password.sql_admin.result
  minimum_tls_version           = "1.2"
  public_network_access_enabled = false
  tags                          = var.tags

  azuread_administrator {
    login_username              = var.entra_admin_login
    object_id                   = var.entra_admin_object_id
    tenant_id                   = var.tenant_id
    azuread_authentication_only = true
  }
}

resource "azurerm_mssql_database" "this" {
  name                 = "mendix"
  server_id            = azurerm_mssql_server.this.id
  collation            = "SQL_Latin1_General_CP1_CI_AS"
  sku_name             = var.sku_name
  max_size_gb          = var.max_size_gb
  zone_redundant       = false
  storage_account_type = "Local"
  geo_backup_enabled   = false
  tags                 = var.tags
}

module "pe" {
  source              = "../private-endpoint"
  name                = "sql-${var.name_prefix}-${var.env}"
  location            = coalesce(var.pe_location, var.location)
  resource_group_name = var.resource_group_name
  subnet_id           = var.pe_subnet_id
  target_resource_id  = azurerm_mssql_server.this.id
  subresource_names   = ["sqlServer"]
  private_dns_zone_id = var.private_dns_zone_id
  tags                = var.tags
}

output "server_id" { value = azurerm_mssql_server.this.id }
output "server_fqdn" { value = azurerm_mssql_server.this.fully_qualified_domain_name }
output "database_name" { value = azurerm_mssql_database.this.name }
output "connection_string" {
  value = "Server=tcp:${azurerm_mssql_server.this.fully_qualified_domain_name},1433;Database=${azurerm_mssql_database.this.name};Authentication=Active Directory Default;Encrypt=true;TrustServerCertificate=false;Connection Timeout=30;"
}
