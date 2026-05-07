terraform {
  required_providers {
    azurerm = { source = "hashicorp/azurerm", version = "~> 4.0" }
  }
}

variable "name_prefix" { type = string }
variable "env" { type = string }
variable "location" { type = string }
variable "resource_group_name" { type = string }
variable "vnet_address_space" { type = string } # e.g. "10.10.0.0/16"
variable "tags" {
  type    = map(string)
  default = {}
}

locals {
  base = "${var.name_prefix}-${var.env}"

  # Subnets: derived from /16 supplied via var.vnet_address_space.
  # Slot map uses cidrsubnet offsets relative to the supplied /16.
  subnets = {
    "snet-aks-nodes" = { newbits = 6, netnum = 0, delegate = null, service_endpoints = [] } # /22
    "snet-agc"       = { newbits = 8, netnum = 4, delegate = "Microsoft.ServiceNetworking/trafficControllers", service_endpoints = [] }
    "snet-pe"        = { newbits = 8, netnum = 5, delegate = null, service_endpoints = [] }
    "snet-mgmt"      = { newbits = 11, netnum = 48, delegate = null, service_endpoints = [] }                                         # /27
    "snet-apiserver" = { newbits = 12, netnum = 98, delegate = "Microsoft.ContainerService/managedClusters", service_endpoints = [] } # /28
  }
}

# ----------------- NSGs (one per subnet) -----------------
resource "azurerm_network_security_group" "this" {
  for_each            = local.subnets
  name                = "nsg-${local.base}-${each.key}"
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = var.tags
}

# AGC requires GatewayManager inbound on 65200-65535 + AzureLoadBalancer
resource "azurerm_network_security_rule" "agc_gw_mgr" {
  name                        = "AllowGatewayManager"
  priority                    = 100
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "65200-65535"
  source_address_prefix       = "GatewayManager"
  destination_address_prefix  = "*"
  resource_group_name         = var.resource_group_name
  network_security_group_name = azurerm_network_security_group.this["snet-agc"].name
}

resource "azurerm_network_security_rule" "agc_lb" {
  name                        = "AllowAzureLoadBalancer"
  priority                    = 110
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "*"
  source_port_range           = "*"
  destination_port_range      = "*"
  source_address_prefix       = "AzureLoadBalancer"
  destination_address_prefix  = "*"
  resource_group_name         = var.resource_group_name
  network_security_group_name = azurerm_network_security_group.this["snet-agc"].name
}

# ----------------- NAT Gateway (egress for AKS nodes) -----------------
resource "azurerm_public_ip" "nat" {
  name                = "pip-${local.base}-nat"
  location            = var.location
  resource_group_name = var.resource_group_name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = var.tags
}

resource "azurerm_nat_gateway" "this" {
  name                    = "natgw-${local.base}"
  location                = var.location
  resource_group_name     = var.resource_group_name
  sku_name                = "Standard"
  idle_timeout_in_minutes = 4
  tags                    = var.tags
}

resource "azurerm_nat_gateway_public_ip_association" "this" {
  nat_gateway_id       = azurerm_nat_gateway.this.id
  public_ip_address_id = azurerm_public_ip.nat.id
}

# ----------------- VNet + Subnets -----------------
resource "azurerm_virtual_network" "this" {
  name                = "vnet-${local.base}"
  address_space       = [var.vnet_address_space]
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = var.tags
}

resource "azurerm_subnet" "this" {
  for_each                          = local.subnets
  name                              = each.key
  resource_group_name               = var.resource_group_name
  virtual_network_name              = azurerm_virtual_network.this.name
  address_prefixes                  = [cidrsubnet(var.vnet_address_space, each.value.newbits, each.value.netnum)]
  service_endpoints                 = each.value.service_endpoints
  private_endpoint_network_policies = each.key == "snet-pe" ? "Disabled" : "Enabled"

  dynamic "delegation" {
    for_each = each.value.delegate == null ? [] : [each.value.delegate]
    content {
      name = "delegation"
      service_delegation {
        name    = delegation.value
        actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
      }
    }
  }
}

resource "azurerm_subnet_network_security_group_association" "this" {
  for_each                  = azurerm_subnet.this
  subnet_id                 = each.value.id
  network_security_group_id = azurerm_network_security_group.this[each.key].id
}

resource "azurerm_subnet_nat_gateway_association" "aks" {
  subnet_id      = azurerm_subnet.this["snet-aks-nodes"].id
  nat_gateway_id = azurerm_nat_gateway.this.id
}

# ----------------- Outputs -----------------
output "vnet_id" { value = azurerm_virtual_network.this.id }
output "vnet_name" { value = azurerm_virtual_network.this.name }
output "subnet_ids" {
  value = { for k, s in azurerm_subnet.this : k => s.id }
}
output "nat_public_ip" { value = azurerm_public_ip.nat.ip_address }
