<#
.SYNOPSIS
  Connect to a target AKS cluster, install ALB Controller (AGC) + Azure Key
  Vault Secrets Provider CSI, then helm-install the mendix-app chart.

.EXAMPLE
  .\scripts\deploy-sample-app.ps1 -Env dev
#>
param(
  [Parameter(Mandatory)][ValidateSet('dev','sit','prod','dr')][string]$Env,
  [string]$RepoRoot = (Resolve-Path "$PSScriptRoot\.."),
  [string]$Subscription = '0832b3b6-22b3-4c47-8d8b-572054b97257'
)
$ErrorActionPreference = 'Stop'

az account set --subscription $Subscription | Out-Null

# Pull outputs from env state
Push-Location (Join-Path $RepoRoot "envs\$Env")
$rg                 = terraform output -raw resource_group
$cluster            = terraform output -raw aks_cluster_name
$kvName             = terraform output -raw key_vault_name
$storageAcct        = terraform output -raw storage_account_name
$workloadClientId   = terraform output -raw workload_identity_client_id
Pop-Location

Push-Location (Join-Path $RepoRoot 'envs\shared')
$tenantId = (az account show --query tenantId -o tsv)
Pop-Location

Write-Host "Getting AKS credentials..."
az aks get-credentials --resource-group $rg --name $cluster --overwrite-existing
kubelogin convert-kubeconfig -l azurecli

# Enable Azure Key Vault Provider for Secrets Store CSI Driver add-on
az aks enable-addons --resource-group $rg --name $cluster --addons azure-keyvault-secrets-provider 2>$null

# ALB Controller
Write-Host "Installing ALB Controller..."
helm install alb-controller oci://mcr.microsoft.com/application-lb/charts/alb-controller `
  --namespace alb-system --create-namespace `
  --version 1.7.9 2>$null

Write-Host "Waiting for ALB Controller to be ready..."
kubectl wait --for=condition=Available --timeout=300s deployment/alb-controller -n alb-system

# Sample app
Write-Host "Deploying mendix-app helm chart..."
helm upgrade --install mendix-app (Join-Path $RepoRoot 'k8s\helm\mendix-app') `
  --namespace mendix --create-namespace `
  --set workloadIdentity.clientId=$workloadClientId `
  --set workloadIdentity.tenantId=$tenantId `
  --set keyVault.name=$kvName `
  --set fileShare.storageAccountName=$storageAcct

Write-Host ""
Write-Host "Deploy complete. Discover the AGC public FQDN with:"
Write-Host "  kubectl get gateway -n mendix mendix-gw -o jsonpath='{.status.addresses[0].value}'"
