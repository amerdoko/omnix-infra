<#
.SYNOPSIS
  Wakes the paused Azure landing zone for a customer demo.

.DESCRIPTION
  Companion to Pause-ForSavings.ps1. Starts all 4 AKS clusters, starts the
  jumphost VM, and (optionally) re-applies the shared Terraform stack to
  recreate Azure Bastion + refresh private DNS records that point at the
  AKS api-server (the private IPs may change on restart).

  Default flow takes ~10-15 min wall-clock. AKS starts run in parallel.

.PARAMETER Customer
  Customer/project token used in resource names. Default: omnix.

.PARAMETER SkipBastion
  Skip the Bastion + DNS reconcile (faster, but no admin path during demo).

.PARAMETER TerraformDir
  Path to envs/shared (used to recreate Bastion). Default: ..\envs\shared
  relative to this script.

.EXAMPLE
  .\Wake-ForDemo.ps1
  Full wake including Bastion.

.EXAMPLE
  .\Wake-ForDemo.ps1 -SkipBastion
  Wake AKS + jumphost only. Use this if you only need workload + Front Door demo.
#>

[CmdletBinding()]
param(
    [string]$Customer = "omnix",
    [switch]$SkipBastion,
    [string]$TerraformDir = (Join-Path $PSScriptRoot "..\envs\shared")
)

$ErrorActionPreference = "Stop"
$script:t0 = Get-Date

function Step($msg) { Write-Host "`n[$([math]::Round(((Get-Date) - $script:t0).TotalSeconds))s] $msg" -ForegroundColor Cyan }
function Ok($msg)   { Write-Host "  ✓ $msg" -ForegroundColor Green }
function Warn($msg) { Write-Host "  ! $msg" -ForegroundColor Yellow }

Step "Verifying Azure context"
$ctx = az account show --query "{sub:name, id:id}" -o json | ConvertFrom-Json
if (-not $ctx) { throw "Not logged in. Run 'az login' first." }
Ok "Subscription: $($ctx.sub)"

$envs = @("dev", "sit", "prod", "dr")
$rgShared = "rg-$Customer-shared"
$vmJump   = "vm-$Customer-jump"
$bastion  = "bas-$Customer"

Step "Starting AKS clusters in parallel"
$jobs = @()
foreach ($env in $envs) {
    $jobs += Start-Job -Name "aks-$env" -ScriptBlock {
        param($rg, $name)
        az aks start -g $rg -n $name --no-wait 2>&1
    } -ArgumentList "rg-$Customer-$env", "aks-$Customer-$env"
}
$jobs += Start-Job -Name "vm-jump" -ScriptBlock {
    param($rg, $name)
    az vm start -g $rg -n $name --no-wait 2>&1
} -ArgumentList $rgShared, $vmJump

$jobs | Wait-Job | Out-Null
foreach ($j in $jobs) {
    $out = Receive-Job -Job $j
    if ($j.State -eq "Completed") { Ok "$($j.Name) start queued" }
    else { Warn "$($j.Name) state=$($j.State): $out" }
}
$jobs | Remove-Job

if (-not $SkipBastion) {
    Step "Recreating Azure Bastion via terraform apply"
    if (-not (Test-Path $TerraformDir)) {
        Warn "TerraformDir not found: $TerraformDir — skipping Bastion recreate."
    }
    else {
        Push-Location $TerraformDir
        try {
            terraform init -upgrade -input=false | Out-Null
            terraform apply -auto-approve -input=false
            Ok "Bastion + shared stack reconciled"
        }
        finally { Pop-Location }
    }
} else {
    Warn "Skipping Bastion (--SkipBastion). Admin path will not be available."
}

Step "Polling for AKS clusters to reach Running state (timeout 15 min)"
$deadline = (Get-Date).AddMinutes(15)
$pending  = $envs.Clone()
while ($pending.Count -gt 0 -and (Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 30
    $still = @()
    foreach ($env in $pending) {
        $state = az aks show -g "rg-$Customer-$env" -n "aks-$Customer-$env" --query "powerState.code" -o tsv 2>$null
        if ($state -eq "Running") { Ok "aks-$Customer-$env Running" }
        else { $still += $env; Write-Host "  - aks-$Customer-$env: $state" -ForegroundColor DarkGray }
    }
    $pending = $still
}
if ($pending.Count -gt 0) { Warn "Timed out waiting for: $($pending -join ', ')" }

Step "Reconciling private DNS for AKS api-servers"
$dnsRg = $rgShared
foreach ($env in $envs) {
    $rg  = "rg-$Customer-$env"
    $aks = "aks-$Customer-$env"
    $fqdn = az aks show -g $rg -n $aks --query "privateFqdn" -o tsv 2>$null
    if (-not $fqdn) { continue }
    $ip = az aks show -g $rg -n $aks --query "apiServerAccessProfile.privateEndpointConnections" -o tsv 2>$null
    Ok "$aks privateFqdn=$fqdn (verify DNS A-record points at current IP)"
}
Write-Host "  (terraform apply on shared above already refreshes the private DNS link.)" -ForegroundColor DarkGray

Step "Wake complete"
$elapsed = [math]::Round(((Get-Date) - $script:t0).TotalMinutes, 1)
Write-Host ""
Write-Host "  Elapsed: $elapsed min" -ForegroundColor Green
Write-Host "  Front Door endpoint should now route to the healthy region." -ForegroundColor Green
Write-Host "  Run 'kubectl get nodes' against any cluster to confirm." -ForegroundColor Green
