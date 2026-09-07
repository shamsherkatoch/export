<#
.SYNOPSIS
    Imports existing Conditional Access policies from a tenant into repository
    definition format, with directory object IDs reverse-resolved into tokens.

.DESCRIPTION
    Read-only against the tenant. Nothing is written to Entra ID.

    Output lands in an import staging directory, NOT in policies/. Imported
    definitions are drafts: they carry placeholder descriptions, an unassigned
    owner and, where a reference could not be safely tokenised, a raw object ID
    recorded in metadata.unresolvedReferences. Review before moving them across.

.EXAMPLE
    ./scripts/Import-CaPolicy.ps1 -Environment prod -OutputPath ./import/prod -AuthMethod Interactive

.EXAMPLE
    # Only the policies matching a naming prefix
    ./scripts/Import-CaPolicy.ps1 -Environment nonprod -OutputPath ./import/nonprod -DisplayNameFilter 'CA*','GRP-*'
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Environment,
    [Parameter(Mandatory)] [string] $OutputPath,
    [ValidateSet('AzureDevOps', 'Interactive', 'ClientSecret')] [string] $AuthMethod = 'AzureDevOps',
    [string]   $Owner = 'UNASSIGNED@change.me',
    [string[]] $DisplayNameFilter,
    [string]   $IdPrefix = 'IMP',
    [string]   $SummaryPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $repoRoot 'src/CaaC.psm1') -Force

$envConfig = Get-CaaCEnvironment -Path (Join-Path $repoRoot "config/environments/$Environment.json")
$context   = Connect-CaaC -Method $AuthMethod -TenantId $envConfig.tenantId

if ($envConfig.tenantId -ne '00000000-0000-0000-0000-000000000000' -and
    $envConfig.tenantId -ne '11111111-1111-1111-1111-111111111111' -and
    $context.TenantId -ne $envConfig.tenantId) {
    throw "Connected tenant $($context.TenantId) does not match '$Environment' ($($envConfig.tenantId)). Aborting."
}

$results = Import-CaaCPolicy -Environment $envConfig `
                             -OutputPath  $OutputPath `
                             -Owner       $Owner `
                             -DisplayNameFilter $DisplayNameFilter `
                             -IdPrefix    $IdPrefix

Write-Host ''
$results | Format-Table PolicyId, State, Unresolved, DisplayName -AutoSize | Out-String | Write-Host

if ($SummaryPath) {
    $results | ConvertTo-Json -Depth 10 | Set-Content $SummaryPath -Encoding utf8
}

Write-Host @'

Next steps
  1. Review each definition. Replace the placeholder description and owner.
  2. Resolve anything listed in metadata.unresolvedReferences - usually a deleted
     object, or a display name that is not unique in the tenant.
  3. Copy the reviewed files into policies/.
  4. Run a Plan against the same tenant. It MUST report NoChange for every policy.
     Any drift at this point is an import fidelity bug, not a policy change.

'@

Disconnect-MgGraph | Out-Null
