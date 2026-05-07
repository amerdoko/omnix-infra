terraform {
  required_version = ">= 1.5.0"
  required_providers {
    azurerm = { source = "hashicorp/azurerm", version = "~> 4.0" }
    random  = { source = "hashicorp/random", version = "~> 3.6" }
  }

  backend "azurerm" {
    # Set via -backend-config or terraform init -backend-config="key=shared.tfstate"
    # Example values populated from bootstrap output:
    #   resource_group_name  = rg-omnix-tfstate
    #   storage_account_name = stomnixtfst<suffix>
    #   container_name       = tfstate
    key              = "shared.tfstate"
    use_azuread_auth = true
  }
}

provider "azurerm" {
  storage_use_azuread = true
  resource_provider_registrations = "none"
  features {}
  subscription_id = var.subscription_id
}

variable "subscription_id" { type = string }
variable "tenant_id" { type = string }
variable "name_prefix" {
  type    = string
  default = "omnix"
}
variable "location_primary" {
  type    = string
  default = "westus2"
}
variable "location_dr" {
  type    = string
  default = "northcentralus"
}
variable "tags" {
  type = map(string)
  default = {
    project = "omnix-mendix"
    layer   = "shared"
    owner   = "amerdoko"
  }
}

resource "azurerm_resource_group" "shared" {
  name     = "rg-${var.name_prefix}-shared"
  location = var.location_primary
  tags     = var.tags
}

# ---------------- Private DNS zones (shared) ----------------
module "private_dns" {
  source              = "../../modules/private-dns"
  resource_group_name = azurerm_resource_group.shared.name
  tags                = var.tags
}

# Region-specific AKS API server zones (BYO so jump host can resolve)
resource "azurerm_private_dns_zone" "aks_primary" {
  name                = "privatelink.${var.location_primary}.azmk8s.io"
  resource_group_name = azurerm_resource_group.shared.name
  tags                = var.tags
}

resource "azurerm_private_dns_zone" "aks_dr" {
  name                = "privatelink.${var.location_dr}.azmk8s.io"
  resource_group_name = azurerm_resource_group.shared.name
  tags                = var.tags
}

# ---------------- Bastion + jump VM + shared VNet ----------------
module "bastion" {
  source              = "../../modules/bastion-jumphost"
  name_prefix         = var.name_prefix
  location            = var.location_primary
  resource_group_name = azurerm_resource_group.shared.name
  vnet_address_space  = "10.99.0.0/16"
  tags                = var.tags
}

# Link standard zones to the shared VNet (so jump host resolves PE FQDNs)
resource "azurerm_private_dns_zone_virtual_network_link" "shared_links" {
  for_each              = module.private_dns.zone_ids
  name                  = "link-shared"
  resource_group_name   = azurerm_resource_group.shared.name
  private_dns_zone_name = module.private_dns.zone_names[each.key]
  virtual_network_id    = module.bastion.vnet_id
  registration_enabled  = false
  tags                  = var.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "shared_aks_primary" {
  name                  = "link-shared"
  resource_group_name   = azurerm_resource_group.shared.name
  private_dns_zone_name = azurerm_private_dns_zone.aks_primary.name
  virtual_network_id    = module.bastion.vnet_id
  registration_enabled  = false
  tags                  = var.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "shared_aks_dr" {
  name                  = "link-shared"
  resource_group_name   = azurerm_resource_group.shared.name
  private_dns_zone_name = azurerm_private_dns_zone.aks_dr.name
  virtual_network_id    = module.bastion.vnet_id
  registration_enabled  = false
  tags                  = var.tags
}

# ---------------- ACR (shared, geo-replicated) ----------------
module "acr" {
  source               = "../../modules/acr"
  name_prefix          = var.name_prefix
  location             = var.location_primary
  geo_replica_location = var.location_dr
  resource_group_name  = azurerm_resource_group.shared.name
  pe_subnet_id         = module.bastion.shared_pe_subnet_id
  private_dns_zone_id  = module.private_dns.zone_ids["privatelink.azurecr.io"]
  tags                 = var.tags
}

# ---------------- Terraform runner (Linux) ----------------

# Dedicated subnet inside the shared vnet for the runner
resource "azurerm_subnet" "runner" {
  name                 = "snet-runner"
  resource_group_name  = azurerm_resource_group.shared.name
  virtual_network_name = module.bastion.vnet_name
  address_prefixes     = [cidrsubnet("10.99.0.0/16", 11, 6)] # 10.99.6.0/27
}

module "tf_runner" {
  source              = "../../modules/tf-runner"
  name_prefix         = var.name_prefix
  location            = var.location_primary
  resource_group_name = azurerm_resource_group.shared.name
  subnet_id           = azurerm_subnet.runner.id
  tags                = var.tags
}

# Sub-scope RBAC for the runner identity
resource "azurerm_role_assignment" "runner_contributor" {
  scope                = "/subscriptions/${var.subscription_id}"
  role_definition_name = "Contributor"
  principal_id         = module.tf_runner.principal_id
}

resource "azurerm_role_assignment" "runner_kv_admin" {
  scope                = "/subscriptions/${var.subscription_id}"
  role_definition_name = "Key Vault Administrator"
  principal_id         = module.tf_runner.principal_id
}

resource "azurerm_role_assignment" "runner_storage_blob" {
  scope                = "/subscriptions/${var.subscription_id}"
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = module.tf_runner.principal_id
}

resource "azurerm_role_assignment" "runner_uaa" {
  scope                = "/subscriptions/${var.subscription_id}"
  role_definition_name = "User Access Administrator"
  principal_id         = module.tf_runner.principal_id
}

# ---------------- Outputs (consumed by env layers) ----------------
output "shared_resource_group" { value = azurerm_resource_group.shared.name }
output "shared_vnet_id" { value = module.bastion.vnet_id }
output "shared_vnet_name" { value = module.bastion.vnet_name }

output "private_dns_zone_ids" {
  value = merge(
    module.private_dns.zone_ids,
    {
      "aks_primary" = azurerm_private_dns_zone.aks_primary.id
      "aks_dr"      = azurerm_private_dns_zone.aks_dr.id
    }
  )
}
output "private_dns_zone_names" {
  value = merge(
    module.private_dns.zone_names,
    {
      "aks_primary" = azurerm_private_dns_zone.aks_primary.name
      "aks_dr"      = azurerm_private_dns_zone.aks_dr.name
    }
  )
}

output "acr_id" { value = module.acr.id }
output "acr_name" { value = module.acr.name }
output "acr_login_server" { value = module.acr.login_server }

output "jump_vm_name" { value = module.bastion.jump_vm_name }
output "jump_vm_admin_user" { value = module.bastion.jump_vm_admin_user }
output "jump_vm_admin_password" {
  value     = module.bastion.jump_vm_admin_password
  sensitive = true
}
output "bastion_name" { value = module.bastion.bastion_name }

# ---- Terraform runner ----
output "tf_runner_vm_name" { value = module.tf_runner.vm_name }
output "tf_runner_admin_user" { value = module.tf_runner.admin_username }
output "tf_runner_private_ip" { value = module.tf_runner.private_ip }
output "tf_runner_principal_id" { value = module.tf_runner.principal_id }
output "tf_runner_ssh_private_key_pem" {
  value     = module.tf_runner.ssh_private_key_pem
  sensitive = true
}

# ---------------- Front Door (DR failover ingress) ----------------
variable "fd_primary_origin_host" {
  type    = string
  default = "placeholder.invalid"
}
variable "fd_dr_origin_host" {
  type    = string
  default = "placeholder.invalid"
}

module "front_door" {
  source              = "../../modules/front-door"
  name_prefix         = var.name_prefix
  resource_group_name = azurerm_resource_group.shared.name
  primary_origin_host = var.fd_primary_origin_host
  dr_origin_host      = var.fd_dr_origin_host
  tags                = var.tags
}

output "front_door_endpoint" { value = module.front_door.endpoint_url }
output "front_door_profile" { value = module.front_door.profile_name }
output "front_door_endpoint_name" { value = module.front_door.endpoint_name }
output "front_door_origin_group" { value = module.front_door.origin_group_name }
