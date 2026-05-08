<#
.SYNOPSIS
  Pauses the Azure landing zone to ~$0 compute spend between demos.

.DESCRIPTION
  Stops all 4 AKS clusters (control planes still billable, but nodes go to $0),
  deallocates the jumphost VM, and deletes Azure Bastion (recreated by
  Wake-ForDemo.ps1 via terraform apply).

  Saves roughly $850/mo of compute. Drip cost ~$400/mo (control planes,
  ACR Premium, Front Door base, Log Analytics, SQL/KV/Storage).

  All operations are queued in parallel and the script returns once they're
  initiated. Verify with 'az aks list -o table' after a couple of minutes.

.PARAMETER Customer
  Customer/project token used in resource names. Default: omnix.

.EXAMPLE
  .\Pause-ForSavings.ps1
#>

[CmdletBinding()]
param(
    [string]$Customer = "omnix"
)

$ErrorActionPreference = "Continue"

Write-Host "Pausing Azure landing zone for customer='$Customer'..." -ForegroundColor Cyan

$ctx = az account show --query "name" -o tsv 2>$null
if (-not $ctx) { throw "Not logged in. Run 'az login' first." }
Write-Host "Subscription: $ctx`n" -ForegroundColor DarkGray

$envs   = @("dev", "sit", "prod", "dr")
$rgSh   = "rg-$Customer-shared"
$vmJump = "vm-$Customer-jump"
$bast   = "bas-$Customer"

$jobs = @()
foreach ($env in $envs) {
    $jobs += Start-Job -Name "aks-$env" -ScriptBlock {
        param($rg, $name) az aks stop -g $rg -n $name --no-wait 2>&1
    } -ArgumentList "rg-$Customer-$env", "aks-$Customer-$env"
}
$jobs += Start-Job -Name "vm-jump" -ScriptBlock {
    param($rg, $name) az vm deallocate -g $rg -n $name --no-wait 2>&1
} -ArgumentList $rgSh, $vmJump
$jobs += Start-Job -Name "bastion" -ScriptBlock {
    param($rg, $name) az network bastion delete -g $rg -n $name --yes 2>&1
} -ArgumentList $rgSh, $bast

$jobs | Wait-Job | Out-Null
foreach ($j in $jobs) {
    if ($j.State -eq "Completed") {
        Write-Host "  ✓ $($j.Name) queued" -ForegroundColor Green
    } else {
        Write-Host "  ! $($j.Name) state=$($j.State)" -ForegroundColor Yellow
        Receive-Job -Job $j | Out-Host
    }
}
$jobs | Remove-Job

Write-Host "`nDone. Verify with:" -ForegroundColor Cyan
Write-Host "  az aks list --query '[].{name:name,state:powerState.code}' -o table" -ForegroundColor Gray
Write-Host "`nWake back up with:" -ForegroundColor Cyan
Write-Host "  .\Wake-ForDemo.ps1" -ForegroundColor Gray
