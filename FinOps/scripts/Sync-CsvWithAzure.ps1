#Requires -Version 7.0
#Requires -Modules Az.Accounts, Az.Resources

<#
.SYNOPSIS
Ensure the tags CSV in SharePoint has a row for every (Subscription, ResourceGroup)
pair currently present under a target management group. Existing rows are NEVER
modified; missing pairs are appended, seeded with the RG's current tag values on
the four managed keys (so humans see reality and can correct as needed).

.DESCRIPTION
  - Read the CSV from SharePoint via Microsoft Graph and capture the drive item's ETag.
  - Enumerate every subscription under -ManagementGroupId, then Set-AzContext +
    Get-AzResourceGroup in each to build the actual (sub, RG) set. Unlike the
    reconciliation task, this one has to look at every subscription - the whole
    point is to discover ones not yet in the CSV.
  - Compute the pairs that are in Azure but not the CSV.
  - Append one row per missing pair, populating SubscriptionName, SubscriptionId
    (if that column exists), ResourceGroupName, and - for each of the four managed
    tag keys - the RG's current tag value on that key (raw, as stored in Azure)
    or an empty cell if the RG has no such tag. Seeding from the RG rather than
    leaving blank means the CSV reflects the real starting state; humans then
    manually correct any values that are wrong, and reconciliation propagates
    those corrections back to Azure.
  - Existing rows are preserved verbatim - this script never rewrites a row that
    is already in the CSV, and never touches the four managed tag columns on
    existing rows even if the RG's Azure tags have drifted. Only the reconciliation
    task writes to Azure, and only from the human-curated CSV.
  - Preserve every existing row and every extra column exactly as read. Column
    order is preserved by rebuilding each new row against the header seen on the
    first existing row.
  - PUT the serialized CSV back to the same drive item, sending If-Match against
    the captured ETag so a concurrent edit fails the run instead of clobbering.
  - WhatIfMode gates the upload: dry-run logs the rows that would be added and
    does not PUT.

.PARAMETER SharePointHostname
Tenant hostname, e.g. "contoso.sharepoint.com".

.PARAMETER SharePointSitePath
Server-relative path to the site, e.g. "/sites/finops".

.PARAMETER CsvItemPath
Drive-root-relative path to the CSV, e.g. "Shared Documents/finops/tags.csv".

.PARAMETER ManagementGroupId
Management group name (not display name) whose subscription tree to scan.

.PARAMETER WhatIfMode
When $true (default), log the rows that would be added but do not PUT the CSV back.
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

$script:ManagedKeys      = @('BusinessUnit', 'CostObject', 'GeneralLedgerCode', 'FinancialDelegate')
$script:RequiredColumns  = @('SubscriptionName', 'ResourceGroupName') + $script:ManagedKeys

function Get-AccessTokenPlain {
    param([Parameter(Mandatory)][string] $ResourceUrl)
    $t = Get-AzAccessToken -ResourceUrl $ResourceUrl
    if ($t.Token -is [System.Security.SecureString]) {
        return [System.Net.NetworkCredential]::new('', $t.Token).Password
    }
    return $t.Token
}

function Get-SharePointCsv {
    param([string] $Hostname, [string] $SitePath, [string] $ItemPath)

    $token   = Get-AccessTokenPlain -ResourceUrl 'https://graph.microsoft.com'
    $headers = @{ Authorization = "Bearer $token" }

    $siteUri = "https://graph.microsoft.com/v1.0/sites/${Hostname}:${SitePath}"
    Write-Host "GET $siteUri"
    $site = Invoke-RestMethod -Method GET -Uri $siteUri -Headers $headers
    Write-Host "  siteId = $($site.id)"

    $encodedSegments = ($ItemPath -split '/') | Where-Object { $_ } | ForEach-Object { [System.Uri]::EscapeDataString($_) }
    $encodedPath = $encodedSegments -join '/'

    # Metadata call gets the drive item's ETag, used later on the PUT's If-Match.
    $metaUri = "https://graph.microsoft.com/v1.0/sites/$($site.id)/drive/root:/${encodedPath}"
    Write-Host "GET $metaUri"
    $meta = Invoke-RestMethod -Method GET -Uri $metaUri -Headers $headers

    $downloadUri = "https://graph.microsoft.com/v1.0/sites/$($site.id)/drive/root:/${encodedPath}:/content"
    Write-Host "GET $downloadUri"
    $raw = Invoke-RestMethod -Method GET -Uri $downloadUri -Headers $headers
    if ($raw -is [byte[]]) { $raw = [System.Text.Encoding]::UTF8.GetString($raw) }
    $rows = @($raw | ConvertFrom-Csv)

    return [pscustomobject]@{
        SiteId      = $site.id
        EncodedPath = $encodedPath
        ETag        = $meta.eTag
        Rows        = $rows
    }
}

function Set-SharePointCsv {
    param(
        [Parameter(Mandatory)][string] $SiteId,
        [Parameter(Mandatory)][string] $EncodedPath,
        [Parameter(Mandatory)][string] $ETag,
        [Parameter(Mandatory)][string] $Content
    )
    $token = Get-AccessTokenPlain -ResourceUrl 'https://graph.microsoft.com'
    $uri = "https://graph.microsoft.com/v1.0/sites/$SiteId/drive/root:/${EncodedPath}:/content"
    $headers = @{
        Authorization  = "Bearer $token"
        'Content-Type' = 'text/csv; charset=utf-8'
        'If-Match'     = $ETag
    }
    Write-Host "PUT $uri (If-Match: $ETag)"
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Content)
    $null = Invoke-RestMethod -Method PUT -Uri $uri -Headers $headers -Body $bytes
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
                $subs.Add([pscustomobject]@{
                    Id   = $node.name
                    Name = $node.properties.displayName
                })
            }
        }
        $uri = if ($resp.PSObject.Properties.Name -contains 'nextLink') { $resp.nextLink } else { $null }
    }
    return $subs
}

function Get-ExistingPairSet {
    # Nested hashtable: $set[<subName lower>][<rgName lower>] = $true.
    # Rows with either match key blank cannot claim a pair unambiguously, so they
    # are ignored - the reconciliation task warns about them separately.
    param([object[]] $Rows)
    $set = @{}
    foreach ($row in $Rows) {
        $subKey = "$($row.SubscriptionName)".Trim().ToLowerInvariant()
        $rgKey  = "$($row.ResourceGroupName)".Trim().ToLowerInvariant()
        if (-not $subKey -or -not $rgKey) { continue }
        if (-not $set.ContainsKey($subKey)) { $set[$subKey] = @{} }
        $set[$subKey][$rgKey] = $true
    }
    return $set
}

# --- main --------------------------------------------------------------------

Write-Host "Reading CSV from SharePoint: https://$SharePointHostname$SharePointSitePath/$CsvItemPath"
$csv = Get-SharePointCsv -Hostname $SharePointHostname -SitePath $SharePointSitePath -ItemPath $CsvItemPath
Write-Host "CSV rows: $($csv.Rows.Count); ETag: $($csv.ETag)"

if ($csv.Rows.Count -eq 0) {
    throw "CSV is empty - cannot infer column order. Populate it with at least a header row before running this task."
}

$existingColumns = @($csv.Rows[0].PSObject.Properties.Name)
foreach ($col in $script:RequiredColumns) {
    if ($existingColumns -notcontains $col) {
        throw "CSV is missing required column: $col"
    }
}

$existing = Get-ExistingPairSet -Rows $csv.Rows
$existingPairCount = ($existing.Values | ForEach-Object { $_.Count } | Measure-Object -Sum).Sum
Write-Host "CSV covers $($existing.Count) subscription(s), $existingPairCount (sub, RG) pair(s)."

$subs = Get-SubscriptionsUnderManagementGroup -ManagementGroupId $ManagementGroupId
Write-Host "Subscriptions under MG '$ManagementGroupId': $($subs.Count)"

$stats = [ordered]@{
    subsInspected = 0
    subsFailed    = 0
    rgsInspected  = 0
    rgsAlready    = 0
    rgsToAppend   = 0
}

$newRows = New-Object System.Collections.Generic.List[object]

foreach ($sub in $subs) {
    $stats.subsInspected++
    Write-Host ""
    Write-Host "=== Subscription: $($sub.Name) ($($sub.Id)) ==="

    try {
        $null = Set-AzContext -SubscriptionId $sub.Id -WarningAction SilentlyContinue
    } catch {
        Write-Warning "Skipping $($sub.Name) ($($sub.Id)) - Set-AzContext failed: $($_.Exception.Message)"
        $stats.subsFailed++
        continue
    }

    $rgs = Get-AzResourceGroup
    $subKey = "$($sub.Name)".Trim().ToLowerInvariant()
    $existingForSub = if ($existing.ContainsKey($subKey)) { $existing[$subKey] } else { @{} }

    foreach ($rg in $rgs) {
        $stats.rgsInspected++
        $rgKey = $rg.ResourceGroupName.ToLowerInvariant()
        if ($existingForSub.ContainsKey($rgKey)) {
            $stats.rgsAlready++
            continue
        }
        $stats.rgsToAppend++

        # Build the new row against the CSV's existing column order so ConvertTo-Csv
        # writes a header identical to what was read. The four managed tag columns
        # are seeded from the RG's current Azure tag value (raw, not normalized) so
        # the CSV reflects the real starting state; unknown extra columns (Owner,
        # Comments, etc.) round-trip as empty strings for the new row.
        $rgTags = @{}
        if ($rg.Tags) {
            foreach ($e in $rg.Tags.GetEnumerator()) { $rgTags[$e.Key] = $e.Value }
        }

        $rowObj = [ordered]@{}
        foreach ($col in $existingColumns) {
            switch ($col) {
                'SubscriptionName'  { $rowObj[$col] = $sub.Name }
                'SubscriptionId'    { $rowObj[$col] = $sub.Id }
                'ResourceGroupName' { $rowObj[$col] = $rg.ResourceGroupName }
                default {
                    if ($script:ManagedKeys -contains $col -and $rgTags.ContainsKey($col)) {
                        $rowObj[$col] = $rgTags[$col]
                    } else {
                        $rowObj[$col] = ''
                    }
                }
            }
        }
        $newRows.Add([pscustomobject]$rowObj)

        $seeded = @($script:ManagedKeys | Where-Object { $rgTags.ContainsKey($_) })
        $seedNote = if ($seeded.Count -gt 0) { " (seeded: $($seeded -join ', '))" } else { '' }
        Write-Host "  + will append: $($sub.Name) / $($rg.ResourceGroupName)$seedNote"
    }
}

Write-Host ""
Write-Host ("Summary: subs inspected={0}, failed={1} | rgs inspected={2}, already in CSV={3}, to append={4}" -f `
    $stats.subsInspected, $stats.subsFailed, $stats.rgsInspected, $stats.rgsAlready, $stats.rgsToAppend)

if ($newRows.Count -eq 0) {
    Write-Host "No new rows - CSV is already in sync. Nothing to upload."
    return
}

if ($WhatIfMode) {
    Write-Host "WhatIf: would append $($newRows.Count) row(s) and PUT the CSV back to SharePoint. Skipping upload."
    return
}

# ConvertTo-Csv emits the header from the first object's property order, which
# for both existing rows (as read by ConvertFrom-Csv) and the new rows (built
# via [ordered] against $existingColumns) is the CSV's original column order.
# Collected into a List rather than `@($csv.Rows) + @($newRows)`: array `+` with a
# List[object] operand throws "Argument types do not match". Don't revert it.
$combined = New-Object System.Collections.Generic.List[object]
foreach ($r in $csv.Rows) { $combined.Add($r) }
foreach ($r in $newRows)  { $combined.Add($r) }
$csvText  = ($combined | ConvertTo-Csv -NoTypeInformation) -join "`r`n"

Set-SharePointCsv -SiteId $csv.SiteId -EncodedPath $csv.EncodedPath -ETag $csv.ETag -Content $csvText
Write-Host "Uploaded updated CSV: +$($newRows.Count) row(s), total rows now $($combined.Count)."
