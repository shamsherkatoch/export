<#
.SYNOPSIS
    Reconciles Conditional Access policy definitions against a tenant.

.EXAMPLE
    # Local dry run against the test tenant
    ./scripts/Invoke-CaDeploy.ps1 -Environment nonprod -Ring Plan -AuthMethod Interactive

.EXAMPLE
    # Adoption check: prove freshly imported definitions are faithful to the tenant
    ./scripts/Invoke-CaDeploy.ps1 -Environment prod -Ring Plan -FailOnChange

.EXAMPLE
    # Pipeline: push new/changed policies in report-only
    ./scripts/Invoke-CaDeploy.ps1 -Environment prod -Ring ReportOnly
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Environment,
    [Parameter(Mandatory)] [ValidateSet('Plan', 'ReportOnly', 'Enforce')] [string] $Ring,
    [ValidateSet('AzureDevOps', 'Interactive', 'ClientSecret')] [string] $AuthMethod = 'AzureDevOps',
    [string[]] $PolicyId,
    [switch]   $AllowCreateInEnforce,
    [switch]   $ForceReportOnly,
    [switch]   $FailOnChange,
    [string]   $SummaryPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $repoRoot 'src/CaaC.psm1') -Force

$envConfig = Get-CaaCEnvironment -Path (Join-Path $repoRoot "config/environments/$Environment.json")
$defs      = Get-CaaCDefinition  -Path (Join-Path $repoRoot 'policies') -PolicyId $PolicyId

if (-not $defs) { throw 'No policy definitions matched.' }
Write-Host "Loaded $($defs.Count) definition(s) for environment '$Environment', ring '$Ring'."

$context = Connect-CaaC -Method $AuthMethod -TenantId $envConfig.tenantId

$placeholderTenants = @('00000000-0000-0000-0000-000000000000', '11111111-1111-1111-1111-111111111111')
if ($envConfig.tenantId -notin $placeholderTenants -and $context.TenantId -ne $envConfig.tenantId) {
    throw "Connected tenant $($context.TenantId) does not match '$Environment' ($($envConfig.tenantId)). Aborting."
}

$results = Invoke-CaaCDeployment -Definition  $defs `
                                 -Environment $envConfig `
                                 -Ring        $Ring `
                                 -AllowCreateInEnforce:$AllowCreateInEnforce `
                                 -ForceReportOnly:$ForceReportOnly

Write-Host ''
$results | Format-Table PolicyId, Action, State, DisplayName -AutoSize | Out-String | Write-Host

if ($SummaryPath) {
    $results | ConvertTo-Json -Depth 10 | Set-Content $SummaryPath -Encoding utf8
    Write-Host "Change set written to $SummaryPath"
}

$changed = @($results | Where-Object Action -ne 'NoChange')
Write-Host "$($changed.Count) of $($results.Count) policies would change."

Disconnect-MgGraph | Out-Null

if ($FailOnChange -and $changed.Count -gt 0) {
    # Used for adoption verification and drift detection. Immediately after import a
    # Plan against the source tenant must be a complete no-op. Anything else means the
    # definition does not faithfully describe the live policy.
    throw "$($changed.Count) policies differ from the tenant while -FailOnChange was set."
}
