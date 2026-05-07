terraform {
  required_providers {
    azurerm = { source = "hashicorp/azurerm", version = "~> 4.0" }
    tls     = { source = "hashicorp/tls", version = "~> 4.0" }
  }
}

variable "name_prefix" { type = string }
variable "location" { type = string }
variable "resource_group_name" { type = string }
variable "subnet_id" { type = string }
variable "vm_size" {
  type    = string
  default = "Standard_D2as_v5"
}
variable "admin_username" {
  type    = string
  default = "tfrunner"
}
variable "terraform_version" {
  type    = string
  default = "1.15.1"
}
variable "auto_shutdown_time" {
  type    = string
  default = "2300"
}
variable "auto_shutdown_timezone" {
  type    = string
  default = "Central Standard Time"
}
variable "tags" {
  type    = map(string)
  default = {}
}

resource "tls_private_key" "ssh" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "azurerm_network_interface" "this" {
  name                = "nic-${var.name_prefix}-tfrunner"
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = var.tags

  ip_configuration {
    name                          = "internal"
    subnet_id                     = var.subnet_id
    private_ip_address_allocation = "Dynamic"
  }
}

locals {
  cloud_init = <<-CLOUDINIT
    #cloud-config
    package_update: true
    package_upgrade: false
    packages:
      - curl
      - unzip
      - git
      - jq
      - ca-certificates
      - gnupg
      - lsb-release
      - apt-transport-https
    runcmd:
      - |
        set -euxo pipefail
        curl -sL https://aka.ms/InstallAzureCLIDeb | bash
        az aks install-cli || true
        curl https://baltocdn.com/helm/signing.asc | gpg --dearmor -o /usr/share/keyrings/helm.gpg
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/helm.gpg] https://baltocdn.com/helm/stable/debian/ all main" > /etc/apt/sources.list.d/helm-stable-debian.list
        apt-get update -y
        apt-get install -y helm
        TFV=${var.terraform_version}
        curl -fsSL -o /tmp/tf.zip "https://releases.hashicorp.com/terraform/$${TFV}/terraform_$${TFV}_linux_amd64.zip"
        unzip -o /tmp/tf.zip -d /usr/local/bin/
        chmod +x /usr/local/bin/terraform
        rm -f /tmp/tf.zip
        echo "tf-runner bootstrap complete" > /var/log/tf-runner-bootstrap.done
  CLOUDINIT
}

resource "azurerm_linux_virtual_machine" "this" {
  name                            = "vm-${var.name_prefix}-tfrunner"
  resource_group_name             = var.resource_group_name
  location                        = var.location
  size                            = var.vm_size
  admin_username                  = var.admin_username
  network_interface_ids           = [azurerm_network_interface.this.id]
  disable_password_authentication = true
  tags                            = var.tags

  admin_ssh_key {
    username   = var.admin_username
    public_key = tls_private_key.ssh.public_key_openssh
  }

  os_disk {
    name                 = "osdisk-${var.name_prefix}-tfrunner"
    caching              = "ReadWrite"
    storage_account_type = "StandardSSD_LRS"
    disk_size_gb         = 64
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts-gen2"
    version   = "latest"
  }

  identity { type = "SystemAssigned" }

  custom_data = base64encode(local.cloud_init)
}

resource "azurerm_dev_test_global_vm_shutdown_schedule" "this" {
  virtual_machine_id    = azurerm_linux_virtual_machine.this.id
  location              = var.location
  enabled               = true
  daily_recurrence_time = var.auto_shutdown_time
  timezone              = var.auto_shutdown_timezone

  notification_settings {
    enabled = false
  }

  tags = var.tags
}

output "vm_id" { value = azurerm_linux_virtual_machine.this.id }
output "vm_name" { value = azurerm_linux_virtual_machine.this.name }
output "principal_id" { value = azurerm_linux_virtual_machine.this.identity[0].principal_id }
output "admin_username" { value = var.admin_username }
output "private_ip" { value = azurerm_network_interface.this.private_ip_address }
output "ssh_private_key_pem" {
  value     = tls_private_key.ssh.private_key_pem
  sensitive = true
}
output "ssh_public_key_openssh" { value = tls_private_key.ssh.public_key_openssh }
