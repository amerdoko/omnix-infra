terraform {
  required_providers {
    azurerm = { source = "hashicorp/azurerm", version = "~> 4.0" }
  }
}

variable "name_prefix" { type = string }
variable "env" { type = string }
variable "location" { type = string }
variable "resource_group_name" { type = string }
variable "node_subnet_id" { type = string }
variable "api_server_subnet_id" { type = string }
variable "log_analytics_workspace_id" { type = string }
variable "private_dns_zone_id" {
  type        = string
  description = "Pre-created privatelink.<region>.azmk8s.io zone in shared RG (BYO)"
}
variable "kubernetes_version" {
  type    = string
  default = null
}
variable "node_count" {
  type    = number
  default = 2
}
variable "node_min_count" {
  type    = number
  default = 2
}
variable "node_max_count" {
  type    = number
  default = 5
}
variable "node_vm_size" {
  type    = string
  default = "Standard_D2as_v5"
}
variable "zone_redundant" {
  type    = bool
  default = false
}
variable "sku_tier" {
  type    = string
  default = "Standard"
}
variable "tenant_id" { type = string }
variable "entra_admin_group_object_ids" {
  type    = list(string)
  default = []
}
variable "tags" {
  type    = map(string)
  default = {}
}

variable "enable_istio" {
  type    = bool
  default = false
}
variable "istio_revisions" {
  type    = list(string)
  default = ["asm-1-23"]
}

resource "azurerm_user_assigned_identity" "aks" {
  name                = "id-${var.name_prefix}-${var.env}-aks"
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = var.tags
}

# AKS control-plane identity needs Private DNS Zone Contributor on the BYO zone
resource "azurerm_role_assignment" "aks_dns_contrib" {
  scope                = var.private_dns_zone_id
  role_definition_name = "Private DNS Zone Contributor"
  principal_id         = azurerm_user_assigned_identity.aks.principal_id
}

# AKS control-plane identity needs Network Contributor on the node subnet
resource "azurerm_role_assignment" "aks_net_contrib" {
  scope                = var.node_subnet_id
  role_definition_name = "Network Contributor"
  principal_id         = azurerm_user_assigned_identity.aks.principal_id
}

resource "azurerm_kubernetes_cluster" "this" {
  name                                = "aks-${var.name_prefix}-${var.env}"
  location                            = var.location
  resource_group_name                 = var.resource_group_name
  dns_prefix                          = "${var.name_prefix}${var.env}"
  kubernetes_version                  = var.kubernetes_version
  sku_tier                            = var.sku_tier
  oidc_issuer_enabled                 = true
  workload_identity_enabled           = true
  azure_policy_enabled                = true
  local_account_disabled              = true
  role_based_access_control_enabled   = true
  private_cluster_enabled             = true
  private_cluster_public_fqdn_enabled = false
  private_dns_zone_id                 = var.private_dns_zone_id
  node_resource_group                 = "rg-${var.name_prefix}-${var.env}-aks-nodes"
  tags                                = var.tags

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.aks.id]
  }

  azure_active_directory_role_based_access_control {
    tenant_id              = var.tenant_id
    admin_group_object_ids = var.entra_admin_group_object_ids
    azure_rbac_enabled     = true
  }

  key_vault_secrets_provider {
    secret_rotation_enabled  = false
    secret_rotation_interval = "2m"
  }

  default_node_pool {
    name                         = "system"
    vm_size                      = var.node_vm_size
    vnet_subnet_id               = var.node_subnet_id
    auto_scaling_enabled         = true
    min_count                    = var.node_min_count
    max_count                    = var.node_max_count
    zones                        = var.zone_redundant ? ["1", "2", "3"] : []
    os_disk_type                 = "Managed"
    os_sku                       = "Ubuntu"
    only_critical_addons_enabled = false
  }

  network_profile {
    network_plugin      = "azure"
    network_plugin_mode = "overlay"
    network_policy      = "azure"
    pod_cidr            = "10.244.0.0/16"
    service_cidr        = "10.0.0.0/16"
    dns_service_ip      = "10.0.0.10"
    outbound_type       = "userAssignedNATGateway"
    load_balancer_sku   = "standard"
  }

  oms_agent {
    log_analytics_workspace_id      = var.log_analytics_workspace_id
    msi_auth_for_monitoring_enabled = true
  }

  dynamic "service_mesh_profile" {
    for_each = var.enable_istio ? [1] : []
    content {
      mode      = "Istio"
      revisions = var.istio_revisions
    }
  }

  microsoft_defender {
    log_analytics_workspace_id = var.log_analytics_workspace_id
  }

  depends_on = [
    azurerm_role_assignment.aks_dns_contrib,
    azurerm_role_assignment.aks_net_contrib,
  ]

  lifecycle {
    ignore_changes = [
      kubernetes_version,              # auto-upgrade owns this
      default_node_pool[0].node_count, # autoscaler owns this
    ]
  }
}

# Allow the cluster's kubelet identity to pull from the shared ACR
variable "acr_id" { type = string }
resource "azurerm_role_assignment" "acr_pull" {
  scope                = var.acr_id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_kubernetes_cluster.this.kubelet_identity[0].object_id
}

output "cluster_id" { value = azurerm_kubernetes_cluster.this.id }
output "cluster_name" { value = azurerm_kubernetes_cluster.this.name }
output "node_resource_group" { value = azurerm_kubernetes_cluster.this.node_resource_group }
output "oidc_issuer_url" { value = azurerm_kubernetes_cluster.this.oidc_issuer_url }
output "kubelet_identity_object_id" {
  value = azurerm_kubernetes_cluster.this.kubelet_identity[0].object_id
}
output "control_plane_identity_id" {
  value = azurerm_user_assigned_identity.aks.id
}
output "control_plane_identity_principal_id" {
  value = azurerm_user_assigned_identity.aks.principal_id
}
