subscription_id    = "1c9d8be3-7bcd-4916-bc6e-bc23993d2a95"
tenant_id          = "f18bd124-cda1-42b5-929a-51779df22782"
name_prefix        = "omnix"
env                = "prod"
location           = "westus2"
vnet_address_space = "10.30.0.0/16"

shared_state_resource_group  = "rg-omnix-tfstate"
shared_state_storage_account = "stomnixtfst4srcwm"
shared_state_container       = "tfstate"

entra_admin_login     = "amerdoko@MngEnvMCAP332153.onmicrosoft.com"
entra_admin_object_id = "14e3c8ad-7c10-426a-9b35-4450048f91bf"

# Production-grade sizing
aks_node_vm_size   = "Standard_D4as_v5"
aks_node_min_count = 2
aks_node_max_count = 6
aks_zone_redundant = false  # westus2 does not support AZs in this sub/SKU
aks_sku_tier       = "Standard"

sql_location             = "centralus"
sql_sku_name             = "S1"
sql_max_size_gb          = 10
storage_replication_type = "GRS"
use_dr_aks_dns_zone      = false

# KV locked from start - apply must run from the Azure-hosted runner (PE-only)
kv_public_network_access_enabled = false
kv_network_acls_default_action   = "Deny"
kv_network_acls_ip_rules         = []

tags = {
  project = "omnix-mendix"
  env     = "prod"
  owner   = "amerdoko"
}
