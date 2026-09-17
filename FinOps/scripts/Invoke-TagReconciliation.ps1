#Requires -Version 7.0
#Requires -Modules Az.Accounts, Az.Resources

<#
.SYNOPSIS
Reconcile Azure resource-group tags against a CSV stored in SharePoint Online.

.DESCRIPTION
See CLAUDE.md at the repo root for the spec. Summary:
  - Read the CSV from SharePoint via Microsoft Graph, using the UAMI's OAuth token.
  - Enumerate every subscription under -ManagementGroupId, then every resource group in each.
  - For each RG whose (SubscriptionId, ResourceGroupName) is present in the CSV,
    reconcile only these tag keys: BusinessUnit, CostObject, GeneralLedgerCode, FinancialDelegate.
  - Values are trimmed of all whitespace and uppercased before compare/write.
  - Writes MERGE — tags outside the four managed keys are never touched.
  - RGs whose row is not in the CSV are left entirely alone.

.PARAMETER SharePointHostname
Tenant hostname, e.g. "contoso.sharepoint.com".

.PARAMETER SharePointSitePath
Server-relative path to the site, e.g. "/sites/finops".

.PARAMETER CsvItemPath
Drive-root-relative path to the CSV, e.g. "Shared Documents/finops/tags.csv".

.PARAMETER ManagementGroupId
Management group name (not display name) whose subscription tree to reconcile.

.PARAMETER WhatIfMode
When $true (default), log intended changes but do not write.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $SharePointHostname,
    [Parameter(Mandatory)] [string] $SharePointSitePath,
    [Parameter(Mandatory)] [string] $CsvItemPath,
    [Parameter(Mandatory)] [string] $ManagementGroupId,
    [Parameter()]          [bool]   $WhatIfMode = $true
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$script:ManagedKeys = @('BusinessUnit', 'CostObject', 'GeneralLedgerCode', 'FinancialDelegate')

function ConvertTo-NormalizedTagValue {
    param([AllowNull()][string] $Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    return ($Value -replace '\s+', '').ToUpperInvariant()
}

function Get-AccessTokenPlain {
    param([Parameter(Mandatory)][string] $ResourceUrl)
    $t = Get-AzAccessToken -ResourceUrl $ResourceUrl
    if ($t.Token -is [System.Security.SecureString]) {
        return [System.Net.NetworkCredential]::new('', $t.Token).Password
    }
    return $t.Token
}

function Invoke-GraphGet {
    param([Parameter(Mandatory)][string] $Uri, [string] $Token)
    if (-not $Token) { $Token = Get-AccessTokenPlain -ResourceUrl 'https://graph.microsoft.com' }
    Invoke-RestMethod -Method GET -Uri $Uri -Headers @{ Authorization = "Bearer $Token" }
}

function Get-CsvFromSharePoint {
    param([string] $Hostname, [string] $SitePath, [string] $ItemPath)

    $token = Get-AccessTokenPlain -ResourceUrl 'https://graph.microsoft.com'

    $siteUri = "https://graph.microsoft.com/v1.0/sites/${Hostname}:${SitePath}"
    $site = Invoke-GraphGet -Uri $siteUri -Token $token

    $encodedSegments = ($ItemPath -split '/') | Where-Object { $_ } | ForEach-Object { [System.Uri]::EscapeDataString($_) }
    $encodedPath = $encodedSegments -join '/'
    $downloadUri = "https://graph.microsoft.com/v1.0/sites/$($site.id)/drive/root:/${encodedPath}:/content"

    $raw = Invoke-RestMethod -Method GET -Uri $downloadUri -Headers @{ Authorization = "Bearer $token" }
    if ($raw -is [byte[]]) { $raw = [System.Text.Encoding]::UTF8.GetString($raw) }
    return @($raw | ConvertFrom-Csv)
}

function Get-SubscriptionsUnderManagementGroup {
    param([string] $ManagementGroupId)
    $token = Get-AccessTokenPlain -ResourceUrl 'https://management.azure.com'
    $uri = "https://management.azure.com/providers/Microsoft.Management/managementGroups/$ManagementGroupId/descendants?api-version=2020-05-01"
    $subs = New-Object System.Collections.Generic.List[string]
    while ($uri) {
        $resp = Invoke-RestMethod -Method GET -Uri $uri -Headers @{ Authorization = "Bearer $token" }
        foreach ($node in $resp.value) {
            if ($node.type -eq 'Microsoft.Management/managementGroups/subscriptions') {
                $subs.Add($node.name)   # $node.name is the subscription GUID
            }
        }
        $uri = $resp.nextLink
    }
    return $subs
}

function New-CsvIndex {
    param([object[]] $Rows)
    if (-not $Rows -or $Rows.Count -eq 0) { throw "CSV is empty." }

    $required = @('SubscriptionId', 'ResourceGroupName') + $script:ManagedKeys
    $present = $Rows[0].PSObject.Properties.Name
    foreach ($col in $required) {
        if ($present -notcontains $col) { throw "CSV is missing required column: $col" }
    }

    $index = @{}
    foreach ($row in $Rows) {
        $subId = "$($row.SubscriptionId)".Trim().ToLowerInvariant()
        $rgName = "$($row.ResourceGroupName)".Trim().ToLowerInvariant()
        if (-not $subId -or -not $rgName) { continue }
        $key = "$subId/$rgName"

        $desired = @{}
        foreach ($k in $script:ManagedKeys) {
            $normalized = ConvertTo-NormalizedTagValue -Value $row.$k
            if ($null -ne $normalized) { $desired[$k] = $normalized }
        }
        $index[$key] = $desired
    }
    return $index
}

function Sync-ResourceGroupTags {
    param(
        [Parameter(Mandatory)] $ResourceGroup,
        [Parameter(Mandatory)][hashtable] $Desired,
        [Parameter(Mandatory)][bool] $WhatIfMode
    )

    $current = @{}
    if ($ResourceGroup.Tags) {
        foreach ($entry in $ResourceGroup.Tags.GetEnumerator()) {
            $current[$entry.Key] = $entry.Value
        }
    }

    $toUpdate = @{}
    foreach ($k in $Desired.Keys) {
        $curVal = $current[$k]
        if ($curVal -ne $Desired[$k]) {
            $toUpdate[$k] = $Desired[$k]
            Write-Host "  [$($ResourceGroup.ResourceGroupName)] $k : '$curVal' -> '$($Desired[$k])'"
        } else {
            Write-Host "  [$($ResourceGroup.ResourceGroupName)] $k : match ('$curVal')"
        }
    }

    if ($toUpdate.Count -eq 0) {
        Write-Host "  [$($ResourceGroup.ResourceGroupName)] no changes"
        return
    }

    if ($WhatIfMode) {
        Write-Host "  [$($ResourceGroup.ResourceGroupName)] WhatIf: would merge $($toUpdate.Count) key(s)"
        return
    }

    $null = Update-AzTag -ResourceId $ResourceGroup.ResourceId -Tag $toUpdate -Operation Merge

    $verify = Get-AzResourceGroup -Name $ResourceGroup.ResourceGroupName
    foreach ($k in $toUpdate.Keys) {
        $actual = $null
        if ($verify.Tags) { $actual = $verify.Tags[$k] }
        if ($actual -ne $toUpdate[$k]) {
            throw "Verify failed for $($ResourceGroup.ResourceGroupName): $k expected '$($toUpdate[$k])' got '$actual'"
        }
    }
    Write-Host "  [$($ResourceGroup.ResourceGroupName)] merged $($toUpdate.Count) key(s) OK"
}

# --- main --------------------------------------------------------------------

Write-Host "Reading CSV from SharePoint: https://$SharePointHostname$SharePointSitePath/$CsvItemPath"
$rows = Get-CsvFromSharePoint -Hostname $SharePointHostname -SitePath $SharePointSitePath -ItemPath $CsvItemPath
Write-Host "CSV rows: $($rows.Count)"

$csvIndex = New-CsvIndex -Rows $rows
Write-Host "Unique (subscription, RG) entries in CSV: $($csvIndex.Count)"

$subs = Get-SubscriptionsUnderManagementGroup -ManagementGroupId $ManagementGroupId
Write-Host "Subscriptions under MG '$ManagementGroupId': $($subs.Count)"

$stats = [ordered]@{ rgsInspected = 0; rgsMatched = 0; rgsUpdated = 0; rgsUnchanged = 0 }

foreach ($subId in $subs) {
    Write-Host ""
    Write-Host "=== Subscription: $subId ==="
    try {
        $null = Set-AzContext -SubscriptionId $subId -WarningAction SilentlyContinue
    } catch {
        Write-Warning "Skipping $subId — Set-AzContext failed: $($_.Exception.Message)"
        continue
    }

    $rgs = Get-AzResourceGroup
    foreach ($rg in $rgs) {
        $stats.rgsInspected++
        $key = "$($subId.ToLowerInvariant())/$($rg.ResourceGroupName.ToLowerInvariant())"
        if (-not $csvIndex.ContainsKey($key)) { continue }
        $stats.rgsMatched++

        $before = @{}
        if ($rg.Tags) { foreach ($e in $rg.Tags.GetEnumerator()) { $before[$e.Key] = $e.Value } }

        Sync-ResourceGroupTags -ResourceGroup $rg -Desired $csvIndex[$key] -WhatIfMode:$WhatIfMode

        $changed = $false
        foreach ($k in $csvIndex[$key].Keys) {
            if ($before[$k] -ne $csvIndex[$key][$k]) { $changed = $true; break }
        }
        if ($changed) { $stats.rgsUpdated++ } else { $stats.rgsUnchanged++ }
    }
}

Write-Host ""
Write-Host "Done. WhatIfMode=$WhatIfMode"
Write-Host ("Summary: inspected={0}, matched={1}, updated={2}, unchanged={3}" -f `
    $stats.rgsInspected, $stats.rgsMatched, $stats.rgsUpdated, $stats.rgsUnchanged)
