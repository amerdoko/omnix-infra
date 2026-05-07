<#
.SYNOPSIS
  Reverse stop-env.ps1: start AKS, scale SQL back up, start jump VM.
.EXAMPLE
  .\scripts\start-env.ps1 -Env dev -SqlSku S0
#>
param(
  [Parameter(Mandatory)][ValidateSet('dev','sit','prod','dr','all')][string]$Env,
  [string]$SqlSku = 'S0',
  [string]$RepoRoot = (Resolve-Path "$PSScriptRoot\.."),
  [string]$Subscription = '0832b3b6-22b3-4c47-8d8b-572054b97257',
  [switch]$IncludeSharedJump
)
$ErrorActionPreference = 'Stop'
az account set --subscription $Subscription | Out-Null

function Start-Env([string]$e) {
  Write-Host ""
  Write-Host "=== Starting $e ==="
  Push-Location (Join-Path $RepoRoot "envs\$e")
  $rg      = terraform output -raw resource_group           2>$null
  $cluster = terraform output -raw aks_cluster_name         2>$null
  $sqlFqdn = terraform output -raw sql_server_fqdn          2>$null
  $sqlDb   = terraform output -raw sql_database_name        2>$null
  Pop-Location

  if ($cluster) {
    Write-Host "Starting AKS $cluster..."
    az aks start --resource-group $rg --name $cluster
  }
  if ($sqlFqdn -and $sqlDb) {
    $serverName = $sqlFqdn.Split('.')[0]
    Write-Host "Scaling SQL DB to $SqlSku..."
    az sql db update --resource-group $rg --server $serverName --name $sqlDb --service-objective $SqlSku
  }
}

if ($Env -eq 'all') {
  foreach ($e in 'dev','sit','prod','dr') { Start-Env $e }
} else {
  Start-Env $Env
}

if ($IncludeSharedJump) {
  Push-Location (Join-Path $RepoRoot 'envs\shared')
  $sharedRg = terraform output -raw shared_resource_group
  $jumpVm   = terraform output -raw jump_vm_name
  Pop-Location
  Write-Host "Starting jump VM $jumpVm..."
  az vm start --resource-group $sharedRg --name $jumpVm
}

Write-Host ""
Write-Host "Done."
