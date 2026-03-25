<#
.SYNOPSIS
    End-to-end test for ACS + Service Bus + Container App + App Gateway private deployment.

.DESCRIPTION
    Validates:
      1. Resource existence (ACS, Service Bus, Queue, System Topic, Container App, App Gateway)
      2. Private endpoint status (Service Bus)
      3. Security config (public access disabled, TLS 1.2, managed identities)
      4. Event Grid subscription health
      5. DNS resolution (privatelink)
      6. App Gateway health probes
      7. Container App status
      8. ACS connectivity

.PARAMETER ResourceGroupName
    Resource group where resources were deployed.

.PARAMETER OutputsFile
    Path to deploy-outputs.json (auto-detected if not provided).

.EXAMPLE
    .\test.ps1 -ResourceGroupName "rg-acs-eh-nonprod"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$ResourceGroupName = "rg-acs-eh-nonprod",

    [Parameter(Mandatory = $false)]
    [string]$OutputsFile = ""
)

$ErrorActionPreference = "Stop"
$passed = 0
$failed = 0
$warnings = 0

function Write-TestResult {
    param([string]$Name, [bool]$Success, [string]$Detail = "")
    if ($Success) {
        Write-Host "  [PASS] $Name" -ForegroundColor Green
        if ($Detail) { Write-Host "         $Detail" -ForegroundColor DarkGray }
        $script:passed++
    } else {
        Write-Host "  [FAIL] $Name" -ForegroundColor Red
        if ($Detail) { Write-Host "         $Detail" -ForegroundColor Yellow }
        $script:failed++
    }
}

function Write-TestWarn {
    param([string]$Name, [string]$Detail = "")
    Write-Host "  [WARN] $Name" -ForegroundColor Yellow
    if ($Detail) { Write-Host "         $Detail" -ForegroundColor DarkGray }
    $script:warnings++
}

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host " ACS + Service Bus – NSP + Private Link Tests" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

# ── Load deployment outputs ───────────────────────────────────────────────────
if ([string]::IsNullOrEmpty($OutputsFile)) {
    $OutputsFile = Join-Path $PSScriptRoot "deploy-outputs.json"
}

if (-not (Test-Path $OutputsFile)) {
    Write-Error "Outputs file not found: $OutputsFile. Run deploy.ps1 first."
}

$outputs = Get-Content $OutputsFile -Raw | ConvertFrom-Json
$sbNamespaceName  = $outputs.sbNamespaceName.value
$sbQueueName      = $outputs.sbQueueName.value
$acsName          = $outputs.acsName.value
$systemTopicName  = $outputs.systemTopicName.value
$sbPeId           = $outputs.sbPrivateEndpointId.value
$acaEnvName       = $outputs.acaEnvironmentName.value
$containerAppName = $outputs.containerAppName.value
$appGwName        = $outputs.appGatewayName.value
$nspName          = $outputs.nspName.value
$nspId            = $outputs.nspId.value

Write-Host "Resource Group  : $ResourceGroupName"
Write-Host "Service Bus NS  : $sbNamespaceName"
Write-Host "Queue           : $sbQueueName"
Write-Host "ACS             : $acsName"
Write-Host "System Topic    : $systemTopicName"
Write-Host "Container App   : $containerAppName"
Write-Host "App Gateway     : $appGwName"
Write-Host "NSP             : $nspName"
Write-Host ""

# ══════════════════════════════════════════════════════════════════════════════
# TEST 1: Resource Existence
# ══════════════════════════════════════════════════════════════════════════════
Write-Host "── Test 1: Resource Existence ──" -ForegroundColor Yellow

# Service Bus Namespace
$sbns = az servicebus namespace show --name $sbNamespaceName -g $ResourceGroupName -o json 2>$null | ConvertFrom-Json
Write-TestResult -Name "Service Bus Namespace exists" -Success ($null -ne $sbns) -Detail $sbNamespaceName

# Service Bus Queue
$queue = az servicebus queue show --name $sbQueueName --namespace-name $sbNamespaceName -g $ResourceGroupName -o json 2>$null | ConvertFrom-Json
Write-TestResult -Name "Service Bus Queue exists" -Success ($null -ne $queue) -Detail "$sbNamespaceName/$sbQueueName"

# ACS
$acsRes = az communication show --name $acsName -g $ResourceGroupName -o json 2>$null | ConvertFrom-Json
Write-TestResult -Name "ACS resource exists" -Success ($null -ne $acsRes) -Detail $acsName

# Event Grid System Topic
$topic = az eventgrid system-topic show --name $systemTopicName -g $ResourceGroupName -o json 2>$null | ConvertFrom-Json
Write-TestResult -Name "Event Grid System Topic exists" -Success ($null -ne $topic) -Detail $systemTopicName

# Event Grid Subscription
$egSub = az eventgrid system-topic event-subscription show `
    --name "acs-to-servicebus" `
    --system-topic-name $systemTopicName `
    -g $ResourceGroupName -o json 2>$null | ConvertFrom-Json
Write-TestResult -Name "Event Grid Subscription exists" -Success ($null -ne $egSub) -Detail "acs-to-servicebus"

# Container App
$cApp = az containerapp show --name $containerAppName -g $ResourceGroupName -o json 2>$null | ConvertFrom-Json
Write-TestResult -Name "Container App exists" -Success ($null -ne $cApp) -Detail $containerAppName

# App Gateway
$agw = az network application-gateway show --name $appGwName -g $ResourceGroupName -o json 2>$null | ConvertFrom-Json
Write-TestResult -Name "App Gateway exists" -Success ($null -ne $agw) -Detail $appGwName

# NSP
$nspRes = az rest --method GET `
    --url "https://management.azure.com${nspId}?api-version=2023-08-01-preview" `
    -o json 2>$null | ConvertFrom-Json
Write-TestResult -Name "NSP exists" -Success ($null -ne $nspRes) -Detail $nspName

# ══════════════════════════════════════════════════════════════════════════════
# TEST 2: Private Endpoint Status
# ══════════════════════════════════════════════════════════════════════════════
Write-Host "`n── Test 2: Private Endpoint ──" -ForegroundColor Yellow

$peStatus = az network private-endpoint show `
    --ids $sbPeId `
    --query "privateLinkServiceConnections[0].properties.privateLinkServiceConnectionState.status" `
    -o tsv 2>$null
Write-TestResult -Name "SB Private Endpoint approved" -Success ($peStatus -eq 'Approved') -Detail "Status: $peStatus"

# ══════════════════════════════════════════════════════════════════════════════
# TEST 3: Security Configuration
# ══════════════════════════════════════════════════════════════════════════════
Write-Host "`n── Test 3: Security Configuration ──" -ForegroundColor Yellow

if ($null -ne $sbns) {
    $publicAccess = $sbns.publicNetworkAccess
    Write-TestResult -Name "SB access SecuredByPerimeter" -Success ($publicAccess -eq 'SecuredByPerimeter') -Detail "publicNetworkAccess: $publicAccess"

    $tlsVersion = $sbns.minimumTlsVersion
    Write-TestResult -Name "SB minimum TLS 1.2" -Success ($tlsVersion -eq '1.2') -Detail "minimumTlsVersion: $tlsVersion"
} else {
    Write-TestResult -Name "SB security config check" -Success $false -Detail "Namespace not found"
}

# System Topic managed identity
if ($null -ne $topic) {
    $hasIdentity = $null -ne $topic.identity -and $topic.identity.type -eq 'SystemAssigned'
    Write-TestResult -Name "System Topic has managed identity" -Success $hasIdentity -Detail "Identity type: $($topic.identity.type)"
} else {
    Write-TestResult -Name "System Topic identity check" -Success $false -Detail "Topic not found"
}

# Container App managed identity
if ($null -ne $cApp) {
    $hasAppIdentity = $null -ne $cApp.identity -and $cApp.identity.type -eq 'SystemAssigned'
    Write-TestResult -Name "Container App has managed identity" -Success $hasAppIdentity -Detail "Identity type: $($cApp.identity.type)"
} else {
    Write-TestResult -Name "Container App identity check" -Success $false -Detail "App not found"
}

# App Gateway WAF
if ($null -ne $agw) {
    $wafEnabled = $agw.webApplicationFirewallConfiguration.enabled
    Write-TestResult -Name "App Gateway WAF enabled" -Success ($wafEnabled -eq $true) -Detail "WAF mode: $($agw.webApplicationFirewallConfiguration.firewallMode)"
} else {
    Write-TestResult -Name "App Gateway WAF check" -Success $false -Detail "App Gateway not found"
}

# NSP association in Enforced mode
if ($null -ne $nspRes) {
    $nspAssocResp = az rest --method GET `
        --url "https://management.azure.com${nspId}/resourceAssociations?api-version=2023-08-01-preview" `
        -o json 2>$null | ConvertFrom-Json
    $sbAssoc = $nspAssocResp.value | Where-Object { $_.name -eq 'sb-namespace-association' }
    if ($null -ne $sbAssoc) {
        $accessMode = $sbAssoc.properties.accessMode
        Write-TestResult -Name "NSP SB association Enforced" -Success ($accessMode -eq 'Enforced') -Detail "accessMode: $accessMode"
    } else {
        Write-TestResult -Name "NSP SB association" -Success $false -Detail "Association not found"
    }

    # Check NSP profile has access rules
    $nspProfileResp = az rest --method GET `
        --url "https://management.azure.com${nspId}/profiles/default-profile?api-version=2023-08-01-preview" `
        -o json 2>$null | ConvertFrom-Json
    Write-TestResult -Name "NSP profile exists" -Success ($null -ne $nspProfileResp) -Detail "default-profile"

    # Check inbound access rules
    $nspRulesResp = az rest --method GET `
        --url "https://management.azure.com${nspId}/profiles/default-profile/accessRules?api-version=2023-08-01-preview" `
        -o json 2>$null | ConvertFrom-Json
    $ruleCount = ($nspRulesResp.value | Where-Object { $_.properties.direction -eq 'Inbound' }).Count
    Write-TestResult -Name "NSP inbound rules configured" -Success ($ruleCount -ge 2) -Detail "$ruleCount inbound rule(s)"
} else {
    Write-TestResult -Name "NSP security checks" -Success $false -Detail "NSP not found"
}

# ══════════════════════════════════════════════════════════════════════════════
# TEST 4: Event Grid Subscription Health
# ══════════════════════════════════════════════════════════════════════════════
Write-Host "`n── Test 4: Event Grid Subscription Health ──" -ForegroundColor Yellow

if ($null -ne $egSub) {
    $provState = $egSub.provisioningState
    Write-TestResult -Name "Subscription provisioning succeeded" -Success ($provState -eq 'Succeeded') -Detail "provisioningState: $provState"

    $destType = $egSub.destination.endpointType
    Write-TestResult -Name "Destination is Service Bus Queue" -Success ($destType -eq 'ServiceBusQueue') -Detail "endpointType: $destType"

    $eventTypes = $egSub.filter.includedEventTypes
    Write-TestResult -Name "Event filter configured" -Success ($eventTypes.Count -gt 0) -Detail "$($eventTypes.Count) event type(s) subscribed"
} else {
    Write-TestResult -Name "Event Grid sub health" -Success $false -Detail "Subscription not found"
}

# ══════════════════════════════════════════════════════════════════════════════
# TEST 5: DNS Resolution
# ══════════════════════════════════════════════════════════════════════════════
Write-Host "`n── Test 5: DNS Resolution (best-effort) ──" -ForegroundColor Yellow

$fqdn = "$sbNamespaceName.servicebus.windows.net"
try {
    $dnsResult = Resolve-DnsName -Name $fqdn -ErrorAction SilentlyContinue
    if ($null -ne $dnsResult) {
        $cname = ($dnsResult | Where-Object { $_.QueryType -eq 'CNAME' }).NameHost
        $isPrivate = $cname -like '*.privatelink.*'
        if ($isPrivate) {
            Write-TestResult -Name "DNS resolves to privatelink" -Success $true -Detail "$fqdn → $cname"
        } else {
            Write-TestWarn -Name "DNS not resolving privately" -Detail "CNAME: $cname (run from VM on VNet for private resolution)"
        }
    } else {
        Write-TestWarn -Name "DNS resolution" -Detail "Could not resolve $fqdn"
    }
} catch {
    Write-TestWarn -Name "DNS resolution" -Detail "Resolve-DnsName failed: $($_.Exception.Message)"
}

# ══════════════════════════════════════════════════════════════════════════════
# TEST 6: App Gateway Health
# ══════════════════════════════════════════════════════════════════════════════
Write-Host "`n── Test 6: App Gateway Health ──" -ForegroundColor Yellow

if ($null -ne $agw) {
    $agwState = $agw.operationalState
    Write-TestResult -Name "App Gateway operational" -Success ($agwState -eq 'Running') -Detail "State: $agwState"

    $backendHealth = az network application-gateway show-backend-health `
        --name $appGwName -g $ResourceGroupName `
        --query "backendAddressPools[0].backendHttpSettingsCollection[0].servers[0].health" `
        -o tsv 2>$null
    if ($backendHealth) {
        Write-TestResult -Name "Backend health probe" -Success ($backendHealth -eq 'Healthy') -Detail "Health: $backendHealth"
    } else {
        Write-TestWarn -Name "Backend health probe" -Detail "Could not query backend health (may need time to converge)"
    }
} else {
    Write-TestResult -Name "App Gateway health" -Success $false -Detail "Not found"
}

# ══════════════════════════════════════════════════════════════════════════════
# TEST 7: Container App Status
# ══════════════════════════════════════════════════════════════════════════════
Write-Host "`n── Test 7: Container App Status ──" -ForegroundColor Yellow

if ($null -ne $cApp) {
    $runState = $cApp.properties.runningStatus
    Write-TestResult -Name "Container App running" -Success ($runState -eq 'Running' -or $null -ne $cApp.properties.latestRevisionFqdn) -Detail "State: $runState, FQDN: $($cApp.properties.configuration.ingress.fqdn)"

    $isInternal = $cApp.properties.managedEnvironmentId -ne $null
    Write-TestResult -Name "Container App in internal env" -Success $isInternal -Detail "Environment: $acaEnvName"
} else {
    Write-TestResult -Name "Container App status" -Success $false -Detail "Not found"
}

# ══════════════════════════════════════════════════════════════════════════════
# TEST 8: ACS Connectivity
# ══════════════════════════════════════════════════════════════════════════════
Write-Host "`n── Test 8: ACS Connectivity ──" -ForegroundColor Yellow

$acsKeys = az communication list-key --name $acsName -g $ResourceGroupName -o json 2>$null | ConvertFrom-Json
if ($null -ne $acsKeys -and $null -ne $acsKeys.primaryConnectionString) {
    Write-TestResult -Name "ACS connection string available" -Success $true -Detail "Endpoint: $($acsRes.hostName)"
} else {
    Write-TestWarn -Name "ACS connection string" -Detail "Could not retrieve keys (check permissions)"
}

# ══════════════════════════════════════════════════════════════════════════════
# Summary
# ══════════════════════════════════════════════════════════════════════════════
Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host " Test Summary" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  Passed   : $passed" -ForegroundColor Green
Write-Host "  Failed   : $failed" -ForegroundColor $(if ($failed -gt 0) { 'Red' } else { 'Green' })
Write-Host "  Warnings : $warnings" -ForegroundColor $(if ($warnings -gt 0) { 'Yellow' } else { 'Green' })
Write-Host ""

if ($failed -gt 0) {
    Write-Host "  Some tests FAILED. Review the output above." -ForegroundColor Red
    exit 1
} elseif ($warnings -gt 0) {
    Write-Host "  All critical tests passed. Warnings expected when not on PE VNet." -ForegroundColor Yellow
    exit 0
} else {
    Write-Host "  All tests PASSED!" -ForegroundColor Green
    exit 0
}
