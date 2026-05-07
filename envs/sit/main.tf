terraform {
  required_version = ">= 1.5.0"
  required_providers {
    azurerm = { source = "hashicorp/azurerm", version = "~> 4.0" }
    random  = { source = "hashicorp/random", version = "~> 3.6" }
  }
  backend "azurerm" {
    key              = "sit.tfstate"
    use_azuread_auth = true
  }
}

provider "azurerm" {
  storage_use_azuread = true
  resource_provider_registrations = "none"
  features {}
  subscription_id = var.subscription_id
}

# -------- Variables --------
variable "subscription_id" { type = string }
variable "tenant_id" { type = string }
variable "name_prefix" {
  type    = string
  default = "omnix"
}
variable "env" { type = string }                # dev | sit | prod | dr
variable "location" { type = string }           # primary or DR location
variable "vnet_address_space" { type = string } # /16 per env
variable "shared_state_resource_group" { type = string }
variable "shared_state_storage_account" { type = string }
variable "shared_state_container" {
  type    = string
  default = "tfstate"
}
variable "entra_admin_login" { type = string }     # SQL Entra admin UPN/email
variable "entra_admin_object_id" { type = string } # SQL Entra admin object id
variable "aks_admin_group_object_ids" {
  type    = list(string)
  default = []
}
variable "aks_node_vm_size" {
  type    = string
  default = "Standard_D2as_v5"
}
variable "aks_node_min_count" {
  type    = number
  default = 2
}
variable "aks_node_max_count" {
  type    = number
  default = 5
}
variable "aks_zone_redundant" {
  type    = bool
  default = false
}
variable "aks_sku_tier" {
  type    = string
  default = "Standard"
}
variable "sql_sku_name" {
  type    = string
  default = "Basic"
} # Basic / S0 / S1 / S2
variable "sql_location" {                          # override SQL server region (PE stays in var.location)
  type    = string
  default = null
}
variable "kv_public_network_access_enabled" {
  type    = bool
  default = false
}
variable "kv_network_acls_default_action" {
  type    = string
  default = "Deny"
}
variable "kv_network_acls_ip_rules" {
  type    = list(string)
  default = []
}
variable "sql_max_size_gb" {
  type    = number
  default = 2
}
variable "storage_replication_type" {
  type    = string
  default = "LRS"
} # GRS for prod
variable "use_dr_aks_dns_zone" {
  type    = bool
  default = false
} # true only for dr env
variable "tags" { type = map(string) }

# -------- Shared layer state --------
data "terraform_remote_state" "shared" {
  backend = "azurerm"
  config = {
    resource_group_name  = var.shared_state_resource_group
    storage_account_name = var.shared_state_storage_account
    container_name       = var.shared_state_container
    key                  = "shared.tfstate"
    use_azuread_auth     = true
  }
}

locals {
  shared_vnet_id   = data.terraform_remote_state.shared.outputs.shared_vnet_id
  shared_vnet_name = data.terraform_remote_state.shared.outputs.shared_vnet_name
  shared_rg_name   = data.terraform_remote_state.shared.outputs.shared_resource_group
  zone_ids         = data.terraform_remote_state.shared.outputs.private_dns_zone_ids
  zone_names       = data.terraform_remote_state.shared.outputs.private_dns_zone_names
  acr_id           = data.terraform_remote_state.shared.outputs.acr_id
  aks_dns_zone_id  = var.use_dr_aks_dns_zone ? local.zone_ids["aks_dr"] : local.zone_ids["aks_primary"]
}

# -------- Resource group --------
resource "azurerm_resource_group" "env" {
  name     = "rg-${var.name_prefix}-${var.env}"
  location = var.location
  tags     = var.tags
}

# -------- Networking --------
module "network" {
  source              = "../../modules/network"
  name_prefix         = var.name_prefix
  env                 = var.env
  location            = var.location
  resource_group_name = azurerm_resource_group.env.name
  vnet_address_space  = var.vnet_address_space
  tags                = var.tags
}

# Peering: env <-> shared (so jump host reaches env private endpoints + AKS API)
resource "azurerm_virtual_network_peering" "env_to_shared" {
  name                         = "peer-${var.env}-to-shared"
  resource_group_name          = azurerm_resource_group.env.name
  virtual_network_name         = module.network.vnet_name
  remote_virtual_network_id    = local.shared_vnet_id
  allow_virtual_network_access = true
  allow_forwarded_traffic      = false
  allow_gateway_transit        = false
  use_remote_gateways          = false
}

resource "azurerm_virtual_network_peering" "shared_to_env" {
  name                         = "peer-shared-to-${var.env}"
  resource_group_name          = local.shared_rg_name
  virtual_network_name         = local.shared_vnet_name
  remote_virtual_network_id    = module.network.vnet_id
  allow_virtual_network_access = true
  allow_forwarded_traffic      = false
  allow_gateway_transit        = false
  use_remote_gateways          = false
}

# Link every shared Private DNS zone to env VNet
resource "azurerm_private_dns_zone_virtual_network_link" "env_links" {
  for_each              = local.zone_ids
  name                  = "link-${var.env}"
  resource_group_name   = local.shared_rg_name
  private_dns_zone_name = local.zone_names[each.key]
  virtual_network_id    = module.network.vnet_id
  registration_enabled  = false
  tags                  = var.tags
}

# -------- Monitoring --------
module "monitoring" {
  source              = "../../modules/monitoring"
  name_prefix         = var.name_prefix
  env                 = var.env
  location            = var.location
  resource_group_name = azurerm_resource_group.env.name
  retention_days      = 30
  tags                = var.tags
}

# -------- Key Vault --------
module "kv" {
  source                         = "../../modules/keyvault"
  name_prefix                    = var.name_prefix
  env                            = var.env
  location                       = var.location
  resource_group_name            = azurerm_resource_group.env.name
  tenant_id                      = var.tenant_id
  pe_subnet_id                   = module.network.subnet_ids["snet-pe"]
  private_dns_zone_id            = local.zone_ids["privatelink.vaultcore.azure.net"]
  log_analytics_workspace_id     = module.monitoring.log_analytics_workspace_id
  public_network_access_enabled  = var.kv_public_network_access_enabled
  network_acls_default_action    = var.kv_network_acls_default_action
  network_acls_ip_rules          = var.kv_network_acls_ip_rules
  tags                           = var.tags
}

# Allow current user (terraform runner) to write secrets
data "azurerm_client_config" "current" {}

resource "azurerm_role_assignment" "kv_secrets_officer_runner" {
  scope                = module.kv.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = data.azurerm_client_config.current.object_id
}

# -------- SQL Database --------
module "sqldb" {
  source                = "../../modules/sqldb"
  name_prefix           = var.name_prefix
  env                   = var.env
  location              = coalesce(var.sql_location, var.location)
  pe_location           = var.location
  resource_group_name   = azurerm_resource_group.env.name
  tenant_id             = var.tenant_id
  entra_admin_login     = var.entra_admin_login
  entra_admin_object_id = var.entra_admin_object_id
  pe_subnet_id          = module.network.subnet_ids["snet-pe"]
  private_dns_zone_id   = local.zone_ids["privatelink.database.windows.net"]
  sku_name              = var.sql_sku_name
  max_size_gb           = var.sql_max_size_gb
  tags                  = var.tags
}

# Persist SQL connection details in KV for the Mendix CSI driver
resource "azurerm_key_vault_secret" "db_connection" {
  name         = "MendixDatabaseConnection"
  value        = module.sqldb.connection_string
  key_vault_id = module.kv.id
  depends_on   = [azurerm_role_assignment.kv_secrets_officer_runner]
}

# -------- Storage (Blob + Files) --------
module "storage" {
  source              = "../../modules/storage"
  name_prefix         = var.name_prefix
  env                 = var.env
  location            = var.location
  resource_group_name = azurerm_resource_group.env.name
  pe_subnet_id        = module.network.subnet_ids["snet-pe"]
  blob_dns_zone_id    = local.zone_ids["privatelink.blob.core.windows.net"]
  file_dns_zone_id    = local.zone_ids["privatelink.file.core.windows.net"]
  replication_type    = var.storage_replication_type
  tags                = var.tags
}

# -------- AKS --------
module "aks" {
  source                       = "../../modules/aks"
  name_prefix                  = var.name_prefix
  env                          = var.env
  location                     = var.location
  resource_group_name          = azurerm_resource_group.env.name
  node_subnet_id               = module.network.subnet_ids["snet-aks-nodes"]
  api_server_subnet_id         = module.network.subnet_ids["snet-apiserver"]
  log_analytics_workspace_id   = module.monitoring.log_analytics_workspace_id
  private_dns_zone_id          = local.aks_dns_zone_id
  node_vm_size                 = var.aks_node_vm_size
  node_min_count               = var.aks_node_min_count
  node_max_count               = var.aks_node_max_count
  zone_redundant               = var.aks_zone_redundant
  sku_tier                     = var.aks_sku_tier
  tenant_id                    = var.tenant_id
  entra_admin_group_object_ids = var.aks_admin_group_object_ids
  acr_id                       = local.acr_id
  tags                         = var.tags
}

# -------- Workload Identity for Mendix app --------
resource "azurerm_user_assigned_identity" "workload" {
  name                = "id-${var.name_prefix}-${var.env}-mendix"
  location            = var.location
  resource_group_name = azurerm_resource_group.env.name
  tags                = var.tags
}

resource "azurerm_role_assignment" "workload_kv_secrets_user" {
  scope                = module.kv.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.workload.principal_id
}

resource "azurerm_role_assignment" "workload_storage_blob" {
  scope                = module.storage.storage_account_id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_user_assigned_identity.workload.principal_id
}

resource "azurerm_federated_identity_credential" "mendix" {
  name                = "fic-mendix"
  resource_group_name = azurerm_resource_group.env.name
  audience            = ["api://AzureADTokenExchange"]
  issuer              = module.aks.oidc_issuer_url
  parent_id           = azurerm_user_assigned_identity.workload.id
  subject             = "system:serviceaccount:mendix:mendix-app"
}

# -------- Outputs --------
output "resource_group" { value = azurerm_resource_group.env.name }
output "vnet_id" { value = module.network.vnet_id }
output "aks_cluster_name" { value = module.aks.cluster_name }
output "aks_node_resource_group" { value = module.aks.node_resource_group }
output "key_vault_name" { value = module.kv.name }
output "sql_server_fqdn" { value = module.sqldb.server_fqdn }
output "sql_database_name" { value = module.sqldb.database_name }
output "storage_account_name" { value = module.storage.storage_account_name }
output "workload_identity_client_id" { value = azurerm_user_assigned_identity.workload.client_id }
output "workload_identity_id" { value = azurerm_user_assigned_identity.workload.id }
output "nat_egress_ip" { value = module.network.nat_public_ip }
