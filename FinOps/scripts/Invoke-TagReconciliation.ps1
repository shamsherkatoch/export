#Requires -Version 7.0
#Requires -Modules Az.Accounts, Az.Resources

<#
.SYNOPSIS
Reconcile Azure resource-group tags against a CSV stored in SharePoint Online.

.DESCRIPTION
Summary:
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
  - After a successful run, render an HTML report and mail it via Microsoft Graph
    (POST /users/{MailFrom}/sendMail) using the same UAMI token.

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

.PARAMETER MailFrom
UPN or object id of the mailbox the report is sent from. Required to send mail.

.PARAMETER MailTo
One or more recipient addresses. Accepts an array, or a single string holding
several addresses separated by ';' or ','. Empty disables the report.

.PARAMETER MailSubject
Subject line base. The run mode and change count are appended to it.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $SharePointHostname,
    [Parameter(Mandatory)] [string] $SharePointSitePath,
    [Parameter(Mandatory)] [string] $CsvItemPath,
    [Parameter(Mandatory)] [string] $ManagementGroupId,
    [Parameter()]          [bool]   $WhatIfMode = $true,
    [Parameter()]          [string] $MailFrom,
    [Parameter()]          [string[]] $MailTo = @(),
    [Parameter()]          [string] $MailSubject = 'Azure RG tag reconciliation'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# ADO surfaces only the exception message, which for .NET overload failures
# ("Argument types do not match") names neither the line nor the call. Print the
# position before rethrowing so a failed run is diagnosable from the log alone.
trap {
    Write-Host "FAILED: $($_.Exception.Message)"
    Write-Host "  at line $($_.InvocationInfo.ScriptLineNumber): $($_.InvocationInfo.Line)"
    Write-Host "  stack: $($_.ScriptStackTrace)"
    throw
}

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

    # Returned wrapped in a scalar object, never as a bare collection: PowerShell
    # unrolls a collection written to the output stream, so a 0- or 1-change RG
    # would reach the caller as $null or a lone object instead of a list.
    $changes = New-Object System.Collections.Generic.List[object]
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
            $changes.Add([pscustomobject]@{ Key = $k; From = $curVal; To = $Desired[$k] })
            Write-Host "  [$($ResourceGroup.ResourceGroupName)] $k : '$curVal' -> '$($Desired[$k])'"
        } else {
            Write-Host "  [$($ResourceGroup.ResourceGroupName)] $k : match ('$curVal')"
        }
    }

    if ($toUpdate.Count -eq 0) {
        Write-Host "  [$($ResourceGroup.ResourceGroupName)] no changes"
        return [pscustomobject]@{ Changes = $changes }
    }

    if ($WhatIfMode) {
        Write-Host "  [$($ResourceGroup.ResourceGroupName)] WhatIf: would merge $($toUpdate.Count) key(s)"
        return [pscustomobject]@{ Changes = $changes }
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
    return [pscustomobject]@{ Changes = $changes }
}

function Resolve-MailRecipients {
    param([AllowNull()][string[]] $Addresses)
    # The pipeline passes To as one string; a caller may pass an array. Accept both,
    # and split on ';' or ',' so "a@x.com; b@y.com" works from a single ADO variable.
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($entry in @($Addresses)) {
        if ([string]::IsNullOrWhiteSpace($entry)) { continue }
        foreach ($part in ($entry -split '[;,]')) {
            $trimmed = $part.Trim()
            if ($trimmed) { $out.Add($trimmed) }
        }
    }
    return $out
}

function ConvertTo-HtmlText {
    param([AllowNull()][string] $Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return '<span style="color:#888;">(not set)</span>' }
    # Plain -replace rather than WebUtility::HtmlEncode — no .NET overload resolution.
    # '&' must be first or it would double-encode the entities added after it.
    return ($Value -replace '&', '&amp;' -replace '<', '&lt;' -replace '>', '&gt;' -replace '"', '&quot;')
}

function New-ReconciliationHtmlReport {
    param(
        [Parameter(Mandatory)] $Stats,
        [Parameter()][AllowEmptyCollection()][object[]] $Results = @(),
        [Parameter(Mandatory)][bool] $WhatIfMode,
        [Parameter(Mandatory)][string] $ManagementGroupId,
        [Parameter(Mandatory)][string] $CsvSource
    )

    $modeLabel = if ($WhatIfMode) { 'DRY RUN — no tags were written' } else { 'LIVE — tags were merged' }
    $modeColor = if ($WhatIfMode) { '#8a6d00' } else { '#0b6b34' }
    $changed   = @($Results | Where-Object { $_.Changes.Count -gt 0 })
    $verb      = if ($WhatIfMode) { 'Would change' } else { 'Changed' }

    $th = 'style="text-align:left;padding:6px 10px;border:1px solid #d0d7de;background:#f3f5f7;font-weight:600;"'
    $td = 'style="text-align:left;padding:6px 10px;border:1px solid #d0d7de;"'

    $runTime = Get-Date -Date ([datetime]::UtcNow) -Format 'yyyy-MM-dd HH:mm:ss'

    # Plain string list + -join rather than StringBuilder: Append() has ~30 overloads
    # and resolving them is a needless failure surface here.
    $html = New-Object System.Collections.Generic.List[object]
    $html.Add('<html><body style="font-family:Segoe UI,Arial,sans-serif;font-size:14px;color:#24292f;">')
    $html.Add('<h2 style="margin:0 0 4px 0;">Azure resource-group tag reconciliation</h2>')
    $html.Add("<p style=""margin:0 0 16px 0;color:$modeColor;font-weight:600;"">$modeLabel</p>")

    $html.Add('<table style="border-collapse:collapse;margin-bottom:20px;">')
    $html.Add("<tr><td $td>Run (UTC)</td><td $td>$runTime</td></tr>")
    $html.Add("<tr><td $td>Management group</td><td $td>$(ConvertTo-HtmlText $ManagementGroupId)</td></tr>")
    $html.Add("<tr><td $td>CSV source</td><td $td>$(ConvertTo-HtmlText $CsvSource)</td></tr>")
    $html.Add('</table>')

    $html.Add('<h3 style="margin:0 0 8px 0;">Summary</h3>')
    $html.Add('<table style="border-collapse:collapse;margin-bottom:20px;">')
    $html.Add("<tr><th $th>Metric</th><th $th>Count</th></tr>")
    # GetEnumerator, not $Stats[$key] — OrderedDictionary exposes both Item[int]
    # and Item[object], so indexing it is the ambiguous form, not the safe one.
    foreach ($entry in $Stats.GetEnumerator()) {
        $html.Add("<tr><td $td>$(ConvertTo-HtmlText $entry.Key)</td><td $td>$($entry.Value)</td></tr>")
    }
    $html.Add('</table>')

    $html.Add("<h3 style=""margin:0 0 8px 0;"">$verb ($($changed.Count) resource group(s))</h3>")
    if ($changed.Count -eq 0) {
        $html.Add('<p>No tag differences found — every matched resource group already agrees with the CSV.</p>')
    } else {
        $html.Add('<table style="border-collapse:collapse;">')
        $html.Add("<tr><th $th>Subscription</th><th $th>Resource group</th><th $th>Tag key</th><th $th>Current</th><th $th>CSV value</th></tr>")
        foreach ($result in $changed) {
            foreach ($change in $result.Changes) {
                $html.Add("<tr><td $td>$(ConvertTo-HtmlText $result.SubscriptionName)</td>" +
                          "<td $td>$(ConvertTo-HtmlText $result.ResourceGroupName)</td>" +
                          "<td $td>$(ConvertTo-HtmlText $change.Key)</td>" +
                          "<td $td>$(ConvertTo-HtmlText $change.From)</td>" +
                          "<td $td>$(ConvertTo-HtmlText $change.To)</td></tr>")
            }
        }
        $html.Add('</table>')
    }

    $html.Add('<p style="margin-top:24px;color:#57606a;font-size:12px;">Generated by Invoke-TagReconciliation.ps1. The SharePoint CSV is the source of truth — correct values there, not in Azure.</p>')
    $html.Add('</body></html>')
    return ($html -join '')
}

function Send-GraphMailReport {
    param(
        [Parameter(Mandatory)][string] $From,
        [Parameter(Mandatory)][string[]] $To,
        [Parameter(Mandatory)][string] $Subject,
        [Parameter(Mandatory)][string] $HtmlBody
    )

    $token = Get-AccessTokenPlain -ResourceUrl 'https://graph.microsoft.com'
    $uri = "https://graph.microsoft.com/v1.0/users/$([System.Uri]::EscapeDataString($From))/sendMail"

    $payload = @{
        message = @{
            subject      = $Subject
            body         = @{ contentType = 'HTML'; content = $HtmlBody }
            toRecipients = @($To | ForEach-Object { @{ emailAddress = @{ address = $_ } } })
        }
        saveToSentItems = $false
    }

    $json = $payload | ConvertTo-Json -Depth 6 -Compress
    Write-Host "POST $uri"
    # sendMail returns 202 with an empty body; swallow it so nothing leaks to the pipeline.
    $null = Invoke-RestMethod -Method POST -Uri $uri `
        -Headers @{ Authorization = "Bearer $token" } `
        -ContentType 'application/json; charset=utf-8' `
        -Body ([System.Text.Encoding]::UTF8.GetBytes($json))
}

# --- main --------------------------------------------------------------------

$csvSource = "https://$SharePointHostname$SharePointSitePath/$CsvItemPath"
Write-Host "Reading CSV from SharePoint: $csvSource"
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

$results = New-Object System.Collections.Generic.List[object]

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

        $sync = Sync-ResourceGroupTags -ResourceGroup $rg -Desired $desired -WhatIfMode:$WhatIfMode

        $results.Add([pscustomobject]@{
            SubscriptionName  = $sub.Name
            ResourceGroupName = $rg.ResourceGroupName
            Changes           = $sync.Changes
        })

        if ($sync.Changes.Count -gt 0) { $stats.rgsUpdated++ } else { $stats.rgsUnchanged++ }
    }
}

Write-Host ""
Write-Host "Done. WhatIfMode=$WhatIfMode"
Write-Host ("Summary: subs inspected={0}, matched={1}, skipped={2} | rgs inspected={3}, matched={4}, updated={5}, unchanged={6}" -f `
    $stats.subsInspected, $stats.subsMatched, $stats.subsSkipped, `
    $stats.rgsInspected, $stats.rgsMatched, $stats.rgsUpdated, $stats.rgsUnchanged)

# --- HTML report --------------------------------------------------------------
# Only reached when the reconciliation above completed without throwing, so the
# report always describes a successful run.

# @() at the call site, not a wrapped return: the function's output unrolls, so an
# empty recipient list has to be re-collected here or $recipients would be $null.
$recipients = @(Resolve-MailRecipients -Addresses $MailTo)

if ($recipients.Count -eq 0) {
    Write-Host ""
    Write-Host "Email report skipped — no MailTo recipients configured."
    return
}
if ([string]::IsNullOrWhiteSpace($MailFrom)) {
    throw "MailTo was supplied but MailFrom is empty. Graph app-only sendMail needs a sender mailbox (UPN or object id)."
}

$html = New-ReconciliationHtmlReport `
    -Stats $stats `
    -Results $results `
    -WhatIfMode $WhatIfMode `
    -ManagementGroupId $ManagementGroupId `
    -CsvSource $csvSource

$modeTag = if ($WhatIfMode) { 'DRY RUN' } else { 'LIVE' }
$subject = "{0} - {1} - {2} RG(s) changed" -f $MailSubject, $modeTag, $stats.rgsUpdated

Write-Host ""
Write-Host "Sending report to $($recipients.Count) recipient(s): $($recipients -join ', ')"
Send-GraphMailReport -From $MailFrom -To $recipients -Subject $subject -HtmlBody $html
Write-Host "Report sent."
