<#
.SYNOPSIS
  Build a Mendix container image from an MDA file using the Mendix Cloud
  Foundry buildpack pattern, then push to the shared ACR.

  Requirements (one-time on your Windows box):
    1. Install Mendix Studio Pro (https://marketplace.mendix.com/link/studiopro/)
    2. Open the sample app of your choice (e.g. "Company Expenses" from the
       Mendix Marketplace) and click "Run Locally" once to generate the .mpk.
    3. From Studio Pro: Project menu -> "Create Deployment Package" -> save .mda
    4. Provide the .mda path to this script.

.EXAMPLE
  .\scripts\build-mendix-image.ps1 `
    -MdaPath "C:\Mendix\CompanyExpenses.mda" `
    -ImageTag "1.0.0"
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)][string]$MdaPath,
  [string]$ImageName = 'omnix-mendix',
  [string]$ImageTag  = 'latest',
  [string]$RepoRoot  = (Resolve-Path "$PSScriptRoot\.."),
  [string]$BuildpackRepo = 'https://github.com/mendix/docker-mendix-buildpack.git'
)
$ErrorActionPreference = 'Stop'

if (-not (Test-Path $MdaPath)) { throw "MDA file not found: $MdaPath" }

# Get ACR login server from shared state
Push-Location (Join-Path $RepoRoot 'envs\shared')
$acrLoginServer = terraform output -raw acr_login_server
$acrName        = terraform output -raw acr_name
Pop-Location

$workDir = Join-Path $env:TEMP 'mendix-build'
if (Test-Path $workDir) { Remove-Item $workDir -Recurse -Force }
New-Item -ItemType Directory -Path $workDir | Out-Null

Write-Host "Cloning Mendix buildpack..."
git clone --depth 1 $BuildpackRepo (Join-Path $workDir 'buildpack')

Copy-Item $MdaPath (Join-Path $workDir 'buildpack\app.mda')

Push-Location (Join-Path $workDir 'buildpack')
try {
  Write-Host "Building image $ImageName`:$ImageTag ..."
  docker build -t "${ImageName}:${ImageTag}" --build-arg BUILD_PATH=app.mda .

  Write-Host "Logging in to ACR $acrName ..."
  az acr login --name $acrName

  $remote = "${acrLoginServer}/${ImageName}:${ImageTag}"
  docker tag "${ImageName}:${ImageTag}" $remote
  docker push $remote

  Write-Host ""
  Write-Host "Pushed: $remote"
  Write-Host "Update your Helm values.yaml:"
  Write-Host "  placeholder.enabled: false"
  Write-Host "  image.repository: $acrLoginServer/$ImageName"
  Write-Host "  image.tag: $ImageTag"
} finally {
  Pop-Location
}
