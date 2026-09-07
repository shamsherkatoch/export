<#
.SYNOPSIS
    Snapshots every Conditional Access policy in the tenant to a pipeline artifact.

.DESCRIPTION
    Conditional Access policies have no soft delete and no built-in version history.
    This snapshot is the only rollback path, so it runs before every write stage and
    the artifact is retained regardless of whether the deployment succeeds.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Environment,
    [Parameter(Mandatory)] [string] $OutputPath,
    [ValidateSet('AzureDevOps', 'Interactive', 'ClientSecret')] [string] $AuthMethod = 'AzureDevOps'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $repoRoot 'src/CaaC.psm1') -Force

$envConfig = Get-CaaCEnvironment -Path (Join-Path $repoRoot "config/environments/$Environment.json")
$null      = Connect-CaaC -Method $AuthMethod -TenantId $envConfig.tenantId

$bundle = Export-CaaCTenantState -OutputPath $OutputPath
Write-Host "##vso[task.setvariable variable=CaSnapshotPath]$bundle"

Disconnect-MgGraph | Out-Null
