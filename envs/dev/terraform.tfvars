subscription_id    = "1c9d8be3-7bcd-4916-bc6e-bc23993d2a95"
tenant_id          = "f18bd124-cda1-42b5-929a-51779df22782"
name_prefix        = "omnix"
env                = "dev"
location           = "westus2"
vnet_address_space = "10.10.0.0/16"

# Shared layer state (fill in storage account name from bootstrap output)
shared_state_resource_group  = "rg-omnix-tfstate"
shared_state_storage_account = "stomnixtfst4srcwm"
shared_state_container       = "tfstate"

entra_admin_login     = "amerdoko@MngEnvMCAP332153.onmicrosoft.com"
entra_admin_object_id = "14e3c8ad-7c10-426a-9b35-4450048f91bf"

aks_node_vm_size   = "Standard_D2as_v5"
aks_node_min_count = 1
aks_node_max_count = 3
aks_zone_redundant = false
aks_sku_tier       = "Standard"

sql_location             = "centralus"
sql_sku_name             = "Basic"
sql_max_size_gb          = 2
storage_replication_type = "LRS"
use_dr_aks_dns_zone      = false

# Allow runner public IP for KV writes (until everything is reachable via Bastion/jump VM)
kv_public_network_access_enabled = true
kv_network_acls_default_action  = "Allow"
kv_network_acls_ip_rules         = []

tags = {
  project = "omnix-mendix"
  env     = "dev"
  owner   = "amerdoko"
}
