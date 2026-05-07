terraform {
  required_providers {
    azurerm = { source = "hashicorp/azurerm", version = "~> 4.0" }
    random  = { source = "hashicorp/random", version = "~> 3.6" }
  }
}

variable "name_prefix" { type = string }
variable "env" { type = string }
variable "location" { type = string }
variable "resource_group_name" { type = string }
variable "pe_subnet_id" { type = string }
variable "blob_dns_zone_id" { type = string }
variable "file_dns_zone_id" { type = string }
variable "replication_type" {
  type    = string
  default = "LRS"
} # GRS for PROD
variable "file_share_quota_gb" {
  type    = number
  default = 100
}
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

resource "azurerm_storage_account" "this" {
  name                            = "st${var.name_prefix}${var.env}${random_string.suffix.result}"
  resource_group_name             = var.resource_group_name
  location                        = var.location
  account_tier                    = "Standard"
  account_replication_type        = var.replication_type
  account_kind                    = "StorageV2"
  min_tls_version                 = "TLS1_2"
  allow_nested_items_to_be_public = false
  shared_access_key_enabled       = false
  public_network_access_enabled   = false
  tags                            = var.tags

  network_rules {
    default_action = "Deny"
    bypass         = ["AzureServices"]
  }
}

resource "azurerm_storage_container" "uploads" {
  name                  = "uploads"
  storage_account_id    = azurerm_storage_account.this.id
  container_access_type = "private"
}

resource "azurerm_storage_share" "mendix" {
  name               = "mendix"
  storage_account_id = azurerm_storage_account.this.id
  quota              = var.file_share_quota_gb
  enabled_protocol   = "SMB"
}

module "pe_blob" {
  source              = "../private-endpoint"
  name                = "st-${var.name_prefix}-${var.env}-blob"
  location            = var.location
  resource_group_name = var.resource_group_name
  subnet_id           = var.pe_subnet_id
  target_resource_id  = azurerm_storage_account.this.id
  subresource_names   = ["blob"]
  private_dns_zone_id = var.blob_dns_zone_id
  tags                = var.tags
}

module "pe_file" {
  source              = "../private-endpoint"
  name                = "st-${var.name_prefix}-${var.env}-file"
  location            = var.location
  resource_group_name = var.resource_group_name
  subnet_id           = var.pe_subnet_id
  target_resource_id  = azurerm_storage_account.this.id
  subresource_names   = ["file"]
  private_dns_zone_id = var.file_dns_zone_id
  tags                = var.tags
}

output "storage_account_id" { value = azurerm_storage_account.this.id }
output "storage_account_name" { value = azurerm_storage_account.this.name }
output "file_share_name" { value = azurerm_storage_share.mendix.name }
output "blob_container_name" { value = azurerm_storage_container.uploads.name }
