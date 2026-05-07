<#
.SYNOPSIS
  Run terraform init + plan for a given env. Used as the gate before apply.
.EXAMPLE
  .\scripts\plan-env.ps1 -Env shared
  .\scripts\plan-env.ps1 -Env dev
#>
param(
  [Parameter(Mandatory)][ValidateSet('shared','dev','sit','prod','dr')][string]$Env,
  [string]$RepoRoot = (Resolve-Path "$PSScriptRoot\.."),
  [string]$Subscription = '0832b3b6-22b3-4c47-8d8b-572054b97257'
)
$ErrorActionPreference = 'Stop'
az account set --subscription $Subscription | Out-Null

# Discover state storage from bootstrap
Push-Location (Join-Path $RepoRoot 'bootstrap')
$rg = terraform output -raw resource_group_name
$sa = terraform output -raw storage_account_name
Pop-Location

Push-Location (Join-Path $RepoRoot "envs\$Env")
try {
  terraform init -reconfigure `
    -backend-config="resource_group_name=$rg" `
    -backend-config="storage_account_name=$sa" `
    -backend-config="container_name=tfstate"
  terraform plan -out tfplan
  Write-Host ""
  Write-Host "Plan saved to envs\$Env\tfplan. Review then run:"
  Write-Host "  cd envs\$Env"
  Write-Host "  terraform apply tfplan"
} finally {
  Pop-Location
}
