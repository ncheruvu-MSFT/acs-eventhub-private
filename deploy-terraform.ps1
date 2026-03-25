<#
.SYNOPSIS
    Deploy ACS + Service Bus + Event Grid + Container App + App Gateway using Terraform.

.DESCRIPTION
    Terraform-based deployment of the full architecture (self-contained):
      - VNet with 3 subnets (PE, ACA, App Gateway) + NSGs
      PUBLIC ZONE:
        - Azure Communication Services (global)
        - Event Grid System Topic (ACS → Service Bus)
        - App Gateway WAF v2 (public entry for ACS voice callbacks)
      PRIVATE ZONE (NSP-protected when Premium):
        - Service Bus (Premium + private endpoint, or Standard)
        - Container App (VNet-injected, polls queue)
        - Private DNS Zones (Premium only)

    No prerequisites — VNet and subnets are created by Terraform.

.PARAMETER SubscriptionId
    (Optional) Target Azure subscription ID. Defaults to current az CLI context.

.PARAMETER ResourceGroupName
    Resource group name for deployment.

.PARAMETER Location
    Azure region.

.PARAMETER AutoApprove
    Skip Terraform interactive approval prompt.

.EXAMPLE
    .\deploy-terraform.ps1 -AutoApprove
    .\deploy-terraform.ps1 -SubscriptionId "64e1939f-..." -Location "eastus2"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$SubscriptionId = "",

    [Parameter(Mandatory = $false)]
    [string]$ResourceGroupName = "rg-acs-eh-nonprod",

    [Parameter(Mandatory = $false)]
    [string]$Location = "eastus2",

    [switch]$AutoApprove
)

$ErrorActionPreference = "Stop"
$TerraformDir = Join-Path $PSScriptRoot "infra" "terraform"

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host " ACS + Service Bus – Terraform Deploy" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

# ── [1/5] Pre-flight checks ────────────────────────────────────────────────
Write-Host "[1/5] Pre-flight checks..." -ForegroundColor Yellow

# Verify az CLI
az version --output none 2>$null
if ($LASTEXITCODE -ne 0) { Write-Error "Azure CLI is not installed or not in PATH." }

# Verify terraform
terraform version -json 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Error "Terraform is not installed or not in PATH." }

if ($SubscriptionId -ne "") {
    Write-Host "  Switching to subscription: $SubscriptionId" -ForegroundColor Magenta
    az account set --subscription $SubscriptionId
    if ($LASTEXITCODE -ne 0) { Write-Error "Failed to set subscription." }
}

$currentSub = (az account show --query '{name:name, id:id}' -o json | ConvertFrom-Json)
if (-not $SubscriptionId) { $SubscriptionId = $currentSub.id }
Write-Host "  Subscription : $($currentSub.name) ($($currentSub.id))" -ForegroundColor Green
Write-Host "  RG           : $ResourceGroupName" -ForegroundColor Green
Write-Host "  Location     : $Location" -ForegroundColor Green

# ── [2/5] Terraform init ───────────────────────────────────────────────────
Write-Host "`n[2/5] Initializing Terraform..." -ForegroundColor Yellow
Push-Location $TerraformDir
terraform init -upgrade
if ($LASTEXITCODE -ne 0) {
    Pop-Location
    Write-Error "Terraform init failed."
}

# ── [3/5] Terraform apply ──────────────────────────────────────────────────
Write-Host "`n[3/5] Applying Terraform configuration..." -ForegroundColor Yellow
Write-Host "  (this may take 15-20 minutes due to App Gateway provisioning)" -ForegroundColor DarkGray

$tfVars = @(
    "-var", "subscription_id=$SubscriptionId",
    "-var", "resource_group_name=$ResourceGroupName",
    "-var", "location=$Location"
)

if ($AutoApprove) {
    terraform apply -auto-approve @tfVars
} else {
    terraform apply @tfVars
}

if ($LASTEXITCODE -ne 0) {
    Pop-Location
    Write-Error "Terraform apply failed."
}

# ── [4/5] Build ACR image & update Container App ──────────────────────────
Write-Host "`n[4/5] Building ACR image and updating Container App..." -ForegroundColor Yellow

$acrName          = terraform output -raw acr_name
$acrLogin         = terraform output -raw acr_login_server
$containerAppName = terraform output -raw container_app_name

$appDir = Join-Path $PSScriptRoot "app"
if (Test-Path $appDir) {
    $imageName = "acs-sample:latest"
    Write-Host "  Building image '$imageName' in ACR '$acrName'..." -ForegroundColor DarkGray
    az acr build --registry $acrName --image $imageName --file "$appDir\Dockerfile" $appDir
    if ($LASTEXITCODE -ne 0) { Write-Error "ACR image build failed." }
    Write-Host "  Image pushed: $acrLogin/$imageName" -ForegroundColor Green

    # Register ACR with Container App using system-assigned managed identity
    Write-Host "  Registering ACR with Container App (system identity)..." -ForegroundColor DarkGray
    az containerapp registry set `
        --name $containerAppName `
        --resource-group $ResourceGroupName `
        --server $acrLogin `
        --identity system
    if ($LASTEXITCODE -ne 0) { Write-Error "Registry set failed." }

    # Update Container App to use the real ACR image
    Write-Host "  Updating Container App image..." -ForegroundColor DarkGray
    az containerapp update `
        --name $containerAppName `
        --resource-group $ResourceGroupName `
        --image "$acrLogin/$imageName"
    if ($LASTEXITCODE -ne 0) { Write-Error "Container App update failed." }
    Write-Host "  Container App updated: $acrLogin/$imageName" -ForegroundColor Green
} else {
    Write-Host "  [SKIP] app/ directory not found – no image to build" -ForegroundColor Yellow
}

# ── [5/5] Summary ─────────────────────────────────────────────────────────
Write-Host "`n[5/5] Deployment Summary" -ForegroundColor Yellow
Write-Host "========================================" -ForegroundColor Cyan
terraform output
Write-Host "========================================" -ForegroundColor Cyan

$appGwPip = terraform output -raw app_gateway_public_ip 2>$null
$caFqdn   = terraform output -raw container_app_fqdn 2>$null

Pop-Location

Write-Host ""
Write-Host "Voice callback URL: http://$appGwPip/api/callback" -ForegroundColor Yellow
Write-Host "  (Configure this in ACS for IncomingCall webhook)" -ForegroundColor DarkGray
Write-Host ""
Write-Host "Container App FQDN: $caFqdn" -ForegroundColor Yellow
Write-Host ""
Write-Host "Next steps:" -ForegroundColor Yellow
Write-Host "  1. Run .\test.ps1 to validate end-to-end"
Write-Host "  2. Add TLS cert to App Gateway for HTTPS"
Write-Host "  3. Point ACS IncomingCall webhook to https://<your-domain>/api/callback"
Write-Host ""
Write-Host "To destroy all resources:" -ForegroundColor DarkGray
Write-Host "  cd infra/terraform && terraform destroy" -ForegroundColor DarkGray
Write-Host ""
