#Requires -Version 7.0
#Requires -Modules Az.Accounts, Az.Resources

<#
.SYNOPSIS
Reconcile Azure resource-group tags against a CSV stored in SharePoint Online.

.DESCRIPTION
See CLAUDE.md at the repo root for the spec. Summary:
  - Read the CSV from SharePoint via Microsoft Graph, using the UAMI's OAuth token.
  - Enumerate every subscription under -ManagementGroupId (returns both id and display name).
  - Match by the pair (SubscriptionName, ResourceGroupName), both case-insensitive.
    Subscriptions with no CSV rows are skipped entirely (no Set-AzContext, no RG listing).
    Inside a matched subscription, only RGs listed in that subscription's CSV rows are touched.
  - For each matched (subscription, RG), reconcile these tag keys against the CSV row:
    BusinessUnit, CostObject, GeneralLedgerCode, FinancialDelegate.
  - Values are trimmed of all whitespace and uppercased before compare/write.
  - Only keys whose current tag value differs from the CSV value are written.
  - Writes MERGE — tags outside the four managed keys are never touched.

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
    Write-Host "GET $siteUri"
    $site = Invoke-GraphGet -Uri $siteUri -Token $token
    Write-Host "  siteId = $($site.id)"

    $encodedSegments = ($ItemPath -split '/') | Where-Object { $_ } | ForEach-Object { [System.Uri]::EscapeDataString($_) }
    $encodedPath = $encodedSegments -join '/'
    $downloadUri = "https://graph.microsoft.com/v1.0/sites/$($site.id)/drive/root:/${encodedPath}:/content"

    Write-Host "GET $downloadUri"
    $raw = Invoke-RestMethod -Method GET -Uri $downloadUri -Headers @{ Authorization = "Bearer $token" }
    if ($raw -is [byte[]]) { $raw = [System.Text.Encoding]::UTF8.GetString($raw) }
    return @($raw | ConvertFrom-Csv)
}

function Get-SubscriptionsUnderManagementGroup {
    param([string] $ManagementGroupId)
    $token = Get-AccessTokenPlain -ResourceUrl 'https://management.azure.com'
    $uri = "https://management.azure.com/providers/Microsoft.Management/managementGroups/$ManagementGroupId/descendants?api-version=2020-05-01"
    $subs = New-Object System.Collections.Generic.List[object]
    while ($uri) {
        $resp = Invoke-RestMethod -Method GET -Uri $uri -Headers @{ Authorization = "Bearer $token" }
        foreach ($node in $resp.value) {
            if ($node.type -eq 'Microsoft.Management/managementGroups/subscriptions') {
                # $node.name is the subscription GUID; $node.properties.displayName is the display name.
                $subs.Add([pscustomobject]@{
                    Id   = $node.name
                    Name = $node.properties.displayName
                })
            }
        }
        # Under Set-StrictMode -Version Latest, accessing a JSON property that isn't
        # present (single-page responses omit `nextLink`) throws. Probe the shape first.
        $uri = if ($resp.PSObject.Properties.Name -contains 'nextLink') { $resp.nextLink } else { $null }
    }
    return $subs
}

function New-CsvIndex {
    param([object[]] $Rows)
    if (-not $Rows -or $Rows.Count -eq 0) { throw "CSV is empty." }

    $required = @('SubscriptionName', 'ResourceGroupName') + $script:ManagedKeys
    $present = $Rows[0].PSObject.Properties.Name
    foreach ($col in $required) {
        if ($present -notcontains $col) { throw "CSV is missing required column: $col" }
    }

    # Nested index: $index[<subName>][<rgName>] = @{ tagKey = normalizedValue }
    $index = @{}
    $skippedRows = 0
    $rowNumber = 1   # header is row 1; data rows start at 2
    foreach ($row in $Rows) {
        $rowNumber++
        $subName = "$($row.SubscriptionName)".Trim().ToLowerInvariant()
        $rgName  = "$($row.ResourceGroupName)".Trim().ToLowerInvariant()
        if (-not $subName -or -not $rgName) {
            Write-Warning "CSV row $rowNumber skipped — missing SubscriptionName or ResourceGroupName (SubscriptionName='$($row.SubscriptionName)', ResourceGroupName='$($row.ResourceGroupName)')."
            $skippedRows++
            continue
        }

        $desired = @{}
        foreach ($k in $script:ManagedKeys) {
            $normalized = ConvertTo-NormalizedTagValue -Value $row.$k
            if ($null -ne $normalized) { $desired[$k] = $normalized }
        }

        if (-not $index.ContainsKey($subName)) { $index[$subName] = @{} }
        $index[$subName][$rgName] = $desired
    }
    if ($skippedRows -gt 0) {
        Write-Host "New-CsvIndex: $skippedRows row(s) skipped due to missing SubscriptionName or ResourceGroupName."
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
        # Normalize BOTH sides identically before compare — same whitespace-strip +
        # ToUpperInvariant treatment used on the CSV. Ensures the compare is
        # case-insensitive and whitespace-insensitive; -ne on the normalized values
        # is then a canonical-form comparison.
        $curNormalized = ConvertTo-NormalizedTagValue -Value $curVal
        if ($curNormalized -ne $Desired[$k]) {
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
$totalRules = ($csvIndex.Values | ForEach-Object { $_.Count } | Measure-Object -Sum).Sum
Write-Host "CSV subscriptions: $($csvIndex.Count); total (sub, RG) rules: $totalRules"

$subs = Get-SubscriptionsUnderManagementGroup -ManagementGroupId $ManagementGroupId
Write-Host "Subscriptions under MG '$ManagementGroupId': $($subs.Count)"

$stats = [ordered]@{
    subsInspected = 0
    subsMatched   = 0
    subsSkipped   = 0
    rgsInspected  = 0
    rgsMatched    = 0
    rgsUpdated    = 0
    rgsUnchanged  = 0
}

foreach ($sub in $subs) {
    $stats.subsInspected++
    Write-Host ""
    Write-Host "=== Subscription: $($sub.Name) ($($sub.Id)) ==="

    $subKey = "$($sub.Name)".Trim().ToLowerInvariant()
    if (-not $csvIndex.ContainsKey($subKey)) {
        Write-Host "  skipped — SubscriptionName '$($sub.Name)' not in CSV"
        $stats.subsSkipped++
        continue
    }
    $stats.subsMatched++
    $rgRules = $csvIndex[$subKey]

    try {
        $null = Set-AzContext -SubscriptionId $sub.Id -WarningAction SilentlyContinue
    } catch {
        Write-Warning "Skipping $($sub.Name) ($($sub.Id)) — Set-AzContext failed: $($_.Exception.Message)"
        continue
    }

    $rgs = Get-AzResourceGroup
    foreach ($rg in $rgs) {
        $stats.rgsInspected++
        $rgKey = $rg.ResourceGroupName.ToLowerInvariant()
        if (-not $rgRules.ContainsKey($rgKey)) { continue }
        $stats.rgsMatched++

        $desired = $rgRules[$rgKey]

        $before = @{}
        if ($rg.Tags) { foreach ($e in $rg.Tags.GetEnumerator()) { $before[$e.Key] = $e.Value } }

        Sync-ResourceGroupTags -ResourceGroup $rg -Desired $desired -WhatIfMode:$WhatIfMode

        $changed = $false
        foreach ($k in $desired.Keys) {
            if ($before[$k] -ne $desired[$k]) { $changed = $true; break }
        }
        if ($changed) { $stats.rgsUpdated++ } else { $stats.rgsUnchanged++ }
    }
}

Write-Host ""
Write-Host "Done. WhatIfMode=$WhatIfMode"
Write-Host ("Summary: subs inspected={0}, matched={1}, skipped={2} | rgs inspected={3}, matched={4}, updated={5}, unchanged={6}" -f `
    $stats.subsInspected, $stats.subsMatched, $stats.subsSkipped, `
    $stats.rgsInspected, $stats.rgsMatched, $stats.rgsUpdated, $stats.rgsUnchanged)
