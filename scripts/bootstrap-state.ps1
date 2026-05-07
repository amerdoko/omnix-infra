<#
.SYNOPSIS
  Bootstrap the Terraform remote state storage account, then update each env
  tfvars file with the generated storage account name.

.EXAMPLE
  .\scripts\bootstrap-state.ps1
#>
[CmdletBinding()]
param(
  [string]$RepoRoot = (Resolve-Path "$PSScriptRoot\.."),
  [string]$Subscription = '0832b3b6-22b3-4c47-8d8b-572054b97257'
)

$ErrorActionPreference = 'Stop'

az account set --subscription $Subscription | Out-Null

Push-Location (Join-Path $RepoRoot 'bootstrap')
try {
  terraform init -upgrade
  terraform apply -auto-approve

  $sa = terraform output -raw storage_account_name
  $rg = terraform output -raw resource_group_name
  Write-Host ""
  Write-Host "Bootstrap complete:"
  Write-Host "  Resource group   : $rg"
  Write-Host "  Storage account  : $sa"

  # Patch shared + env tfvars files
  $envs = @('shared','dev','sit','prod','dr')
  foreach ($env in $envs) {
    $tfvars = Join-Path $RepoRoot "envs\$env\terraform.tfvars"
    if (-not (Test-Path $tfvars)) { continue }
    if ($env -eq 'shared') { continue }   # shared has no remote-state pointer
    (Get-Content $tfvars -Raw) `
      -replace 'shared_state_storage_account = "[^"]*"', "shared_state_storage_account = `"$sa`"" `
      | Set-Content $tfvars -NoNewline
    Write-Host "  Patched $tfvars"
  }
} finally {
  Pop-Location
}

Write-Host ""
Write-Host "Next: deploy shared layer."
Write-Host "  cd envs\shared"
Write-Host "  terraform init -backend-config=`"resource_group_name=$rg`" -backend-config=`"storage_account_name=$sa`" -backend-config=`"container_name=tfstate`""
Write-Host "  terraform plan"
