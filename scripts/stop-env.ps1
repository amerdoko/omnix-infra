<#
.SYNOPSIS
  Stop AKS + scale SQL down + deallocate jump host to minimize cost between demos.
.EXAMPLE
  .\scripts\stop-env.ps1 -Env dev
  .\scripts\stop-env.ps1 -Env all
#>
param(
  [Parameter(Mandatory)][ValidateSet('dev','sit','prod','dr','all')][string]$Env,
  [string]$RepoRoot = (Resolve-Path "$PSScriptRoot\.."),
  [string]$Subscription = '0832b3b6-22b3-4c47-8d8b-572054b97257',
  [switch]$IncludeSharedJump
)
$ErrorActionPreference = 'Stop'
az account set --subscription $Subscription | Out-Null

function Stop-Env([string]$e) {
  Write-Host ""
  Write-Host "=== Stopping $e ==="
  Push-Location (Join-Path $RepoRoot "envs\$e")
  $rg      = terraform output -raw resource_group           2>$null
  $cluster = terraform output -raw aks_cluster_name         2>$null
  $sqlFqdn = terraform output -raw sql_server_fqdn          2>$null
  $sqlDb   = terraform output -raw sql_database_name        2>$null
  Pop-Location

  if ($cluster) {
    Write-Host "Stopping AKS $cluster..."
    az aks stop --resource-group $rg --name $cluster --no-wait
  }
  if ($sqlFqdn -and $sqlDb) {
    $serverName = $sqlFqdn.Split('.')[0]
    Write-Host "Scaling SQL DB to Basic..."
    az sql db update --resource-group $rg --server $serverName --name $sqlDb --service-objective Basic 2>$null
  }
}

if ($Env -eq 'all') {
  foreach ($e in 'dev','sit','prod','dr') { Stop-Env $e }
} else {
  Stop-Env $Env
}

if ($IncludeSharedJump) {
  Push-Location (Join-Path $RepoRoot 'envs\shared')
  $sharedRg = terraform output -raw shared_resource_group
  $jumpVm   = terraform output -raw jump_vm_name
  Pop-Location
  Write-Host "Deallocating jump VM $jumpVm..."
  az vm deallocate --resource-group $sharedRg --name $jumpVm --no-wait
}

Write-Host ""
Write-Host "Done. Remember: ACR Premium (~$1.67/day), NAT GW (~$1/day per env), and Bastion (~$4.65/day) keep running."
Write-Host "To kill Bastion fully, run: terraform destroy -target=module.bastion in envs\shared (after demo cycle)."
