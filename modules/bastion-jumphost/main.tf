terraform {
  required_providers {
    azurerm = { source = "hashicorp/azurerm", version = "~> 4.0" }
    random  = { source = "hashicorp/random", version = "~> 3.6" }
  }
}

variable "name_prefix" { type = string }
variable "location" { type = string }
variable "resource_group_name" { type = string }
variable "vnet_address_space" {
  type    = string
  default = "10.99.0.0/16"
}
variable "vm_size" {
  type    = string
  default = "Standard_D2as_v5"
}
variable "admin_username" {
  type    = string
  default = "azureuser"
}
variable "tags" {
  type    = map(string)
  default = {}
}

resource "random_password" "vm_admin" {
  length           = 20
  special          = true
  override_special = "!@#$%-_"
  min_upper        = 2
  min_lower        = 2
  min_numeric      = 2
  min_special      = 2
}

# ---- Shared VNet ----
resource "azurerm_virtual_network" "shared" {
  name                = "vnet-${var.name_prefix}-shared"
  address_space       = [var.vnet_address_space]
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = var.tags
}

resource "azurerm_subnet" "bastion" {
  name                 = "AzureBastionSubnet"
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.shared.name
  address_prefixes     = [cidrsubnet(var.vnet_address_space, 11, 0)] # /27
}

resource "azurerm_subnet" "jump" {
  name                 = "snet-jumphost"
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.shared.name
  address_prefixes     = [cidrsubnet(var.vnet_address_space, 11, 1)] # /27
}

resource "azurerm_subnet" "shared_pe" {
  name                              = "snet-shared-pe"
  resource_group_name               = var.resource_group_name
  virtual_network_name              = azurerm_virtual_network.shared.name
  address_prefixes                  = [cidrsubnet(var.vnet_address_space, 11, 2)] # /27
  private_endpoint_network_policies = "Disabled"
}

# ---- Bastion ----
resource "azurerm_public_ip" "bastion" {
  name                = "pip-${var.name_prefix}-bastion"
  location            = var.location
  resource_group_name = var.resource_group_name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = var.tags
}

resource "azurerm_bastion_host" "this" {
  name                = "bas-${var.name_prefix}"
  location            = var.location
  resource_group_name = var.resource_group_name
  sku                 = "Standard"
  tags                = var.tags

  ip_configuration {
    name                 = "ipconfig"
    subnet_id            = azurerm_subnet.bastion.id
    public_ip_address_id = azurerm_public_ip.bastion.id
  }
}

# ---- Jump VM (Windows) ----
resource "azurerm_network_interface" "jump" {
  name                = "nic-${var.name_prefix}-jump"
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = var.tags

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.jump.id
    private_ip_address_allocation = "Dynamic"
  }
}

resource "azurerm_windows_virtual_machine" "jump" {
  name                  = "vm-${var.name_prefix}-jump"
  resource_group_name   = var.resource_group_name
  location              = var.location
  size                  = var.vm_size
  admin_username        = var.admin_username
  admin_password        = random_password.vm_admin.result
  network_interface_ids = [azurerm_network_interface.jump.id]
  secure_boot_enabled   = true
  vtpm_enabled          = true
  tags                  = var.tags

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "StandardSSD_LRS"
  }

  source_image_reference {
    publisher = "MicrosoftWindowsDesktop"
    offer     = "Windows-11"
    sku       = "win11-23h2-pro"
    version   = "latest"
  }

  identity { type = "SystemAssigned" }
}

# Install az / kubectl / helm / kubelogin via PowerShell extension
# Tools (az/kubectl/helm) installed manually after deploy via Bastion RDP.
# To install: RDP via Bastion, open PowerShell as admin, run:
#   Set-ExecutionPolicy Bypass -Scope Process -Force; iex ((New-Object Net.WebClient).DownloadString('https://chocolatey.org/install.ps1'))
#   choco install -y azure-cli kubernetes-cli kubernetes-helm
#   az aks install-cli

output "vnet_id" { value = azurerm_virtual_network.shared.id }
output "vnet_name" { value = azurerm_virtual_network.shared.name }
output "shared_pe_subnet_id" { value = azurerm_subnet.shared_pe.id }
output "jump_vm_id" { value = azurerm_windows_virtual_machine.jump.id }
output "jump_vm_name" { value = azurerm_windows_virtual_machine.jump.name }
output "jump_vm_admin_user" { value = var.admin_username }
output "jump_vm_admin_password" {
  value     = random_password.vm_admin.result
  sensitive = true
}
output "bastion_name" { value = azurerm_bastion_host.this.name }
