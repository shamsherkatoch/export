#Requires -Version 7.0
#Requires -Modules Az.Accounts, Az.Resources

<#
.SYNOPSIS
Reconcile Azure resource-group tags against a CSV stored in SharePoint Online.

.DESCRIPTION
Summary:
  - Read the CSV from SharePoint via Microsoft Graph, using the home tenant UAMI's
    OAuth token (the home tenant is the one the task's service connection signs in to).
  - For each tenant in -TenantScopes, become that tenant's own UAMI - the task's
    login for the home tenant, a fresh Azure DevOps OIDC token for that tenant's
    service connection otherwise - then enumerate every subscription
    under that tenant's management group (returns both id and display name).
  - Match by the triple (TenantId, SubscriptionName, ResourceGroupName), all case-insensitive.
    Tenants with no CSV rows are not signed in to. Subscriptions with no CSV rows are
    skipped entirely (no Set-AzContext, no RG listing).
    Inside a matched subscription, only RGs listed in that subscription's CSV rows are touched.
  - For each matched (subscription, RG), reconcile these tag keys against the CSV row:
    BusinessUnit, CostObject, GeneralLedgerCode, FinancialDelegate.
  - Values are trimmed of all whitespace and uppercased before compare/write.
  - Only keys whose current tag value differs from the CSV value are written.
  - Writes MERGE - tags outside the four managed keys are never touched.
  - After a successful live run, render an HTML report and mail it via Microsoft Graph
    (POST /users/{MailFrom}/sendMail) from the home tenant. WhatIf runs send no mail.

.PARAMETER SharePointHostname
Tenant hostname, e.g. "contoso.sharepoint.com".

.PARAMETER SharePointSitePath
Server-relative path to the site, e.g. "/sites/finops".

.PARAMETER CsvItemPath
Drive-root-relative path to the CSV, e.g. "Shared Documents/finops/tags.csv".

.PARAMETER TenantScopes
The tenants to reconcile and the management group to scan in each, as
"<tenantId>=<managementGroupName>" entries separated by ';' or ','. One entry per tenant.

.PARAMETER TenantConnections
For every tenant in -TenantScopes other than the home tenant (the one the task is
signed in to): "<tenantId>=<clientId>:<serviceConnectionId>" - the client id of that
tenant's UAMI and the id of the Azure DevOps service connection backed by it.
Entries separated by ','. Not needed for a single-tenant run.

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
    [Parameter(Mandatory)] [string] $TenantScopes,
    [Parameter()]          [string] $TenantConnections,
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

function Resolve-TenantScopes {
    # "tenantA-guid=mgA;tenantB-guid=mgB" -> one {TenantId, ManagementGroupId} per entry.
    # The tenant list has to come from configuration, not the CSV: the sync task must
    # discover RGs in a tenant that has no CSV rows yet, and the CSV holds no MG.
    param([AllowNull()][string] $Value)
    $out  = New-Object System.Collections.Generic.List[object]
    $seen = @{}
    foreach ($part in ("$Value" -split '[;,]')) {
        $entry = $part.Trim()
        if (-not $entry) { continue }
        $pieces = @($entry -split '=', 2)
        if ($pieces.Count -ne 2) {
            throw "TenantScopes entry '$entry' is not in the form <tenantId>=<managementGroupId>."
        }
        $tenantId = $pieces[0].Trim().ToLowerInvariant()
        $mgId     = $pieces[1].Trim()
        if ($tenantId -notmatch '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$') {
            throw "TenantScopes entry '$entry': '$tenantId' is not a tenant GUID."
        }
        if (-not $mgId) { throw "TenantScopes entry '$entry' has an empty management group id." }
        # One MG per tenant. Two MGs in one tenant could overlap, and a subscription
        # seen twice would be processed (and, in the sync task, appended) twice.
        if ($seen.ContainsKey($tenantId)) { throw "TenantScopes lists tenant '$tenantId' more than once." }
        $seen[$tenantId] = $true
        $out.Add([pscustomobject]@{ TenantId = $tenantId; ManagementGroupId = $mgId })
    }
    return $out
}

function Resolve-TenantConnections {
    # "tenantB-guid=clientId:serviceConnectionId" -> @{ tenantId = {ClientId, ServiceConnectionId} }.
    # One entry per tenant OTHER than the home tenant: the identity (a UAMI in that
    # tenant) and the Azure DevOps service connection used to sign in to it. The home
    # tenant needs no entry - the task is already signed in there.
    param([AllowNull()][string] $Value)
    $map = @{}
    foreach ($part in ("$Value" -split '[;,]')) {
        $entry = $part.Trim()
        if (-not $entry) { continue }
        $pieces = @($entry -split '=', 2)
        $ids = if ($pieces.Count -eq 2) { @($pieces[1] -split ':', 2) } else { @() }
        if ($ids.Count -ne 2 -or -not $pieces[0].Trim() -or -not $ids[0].Trim() -or -not $ids[1].Trim()) {
            throw "TenantConnections entry '$entry' is not in the form <tenantId>=<clientId>:<serviceConnectionId>."
        }
        $map[$pieces[0].Trim().ToLowerInvariant()] = [pscustomobject]@{
            ClientId            = $ids[0].Trim()
            ServiceConnectionId = $ids[1].Trim()
        }
    }
    return $map
}

function Get-PipelineOidcToken {
    # Ask Azure DevOps for a fresh OIDC token for a service connection - the federated
    # assertion that connection's UAMI trusts. Works for a connection other than the
    # one the task runs under, as long as the pipeline is authorized to use it.
    param([Parameter(Mandatory)][string] $ServiceConnectionId)
    $requestUri  = $env:SYSTEM_OIDCREQUESTURI
    $systemToken = $env:SYSTEM_ACCESSTOKEN
    if (-not $requestUri -or -not $systemToken) {
        throw ("Cannot switch tenant: SYSTEM_OIDCREQUESTURI and SYSTEM_ACCESSTOKEN must both be set. The first " +
               "comes from the pipeline agent; SYSTEM_ACCESSTOKEN must be mapped in the task's env: block.")
    }
    $uri = "${requestUri}?api-version=7.1&serviceConnectionId=$ServiceConnectionId"
    try {
        $resp = Invoke-RestMethod -Method POST -Uri $uri `
            -Headers @{ Authorization = "Bearer $systemToken" } `
            -ContentType 'application/json'
    } catch {
        if ($_.PSObject.Properties.Name -contains 'ErrorDetails' -and $_.ErrorDetails) {
            Write-Host "  Azure DevOps OIDC token error (service connection $ServiceConnectionId): $($_.ErrorDetails.Message)"
        }
        throw
    }
    return $resp.oidcToken
}

function Connect-Tenant {
    # Make $TenantId the tenant of the default Az context. No-op when it already is.
    # Home tenant: go back to the login the AzurePowerShell task made (its UAMI).
    # Any other tenant: sign in as that tenant's own UAMI with a fresh OIDC token for
    # that tenant's service connection. Each tenant has its own identity - no secret,
    # and nothing shared across tenants.
    param([Parameter(Mandatory)][string] $TenantId)
    $ctx = Get-AzContext
    if ($ctx -and $ctx.Tenant -and "$($ctx.Tenant.Id)" -eq $TenantId) { return }

    if ($TenantId -eq $script:HomeTenantId) {
        Write-Host "Switching back to home tenant $TenantId"
        $null = Set-AzContext -Context $script:HomeContext -WarningAction SilentlyContinue
        return
    }

    if (-not $script:TenantConnectionMap.ContainsKey($TenantId)) {
        throw "No TenantConnections entry for tenant $TenantId."
    }
    $conn = $script:TenantConnectionMap[$TenantId]
    Write-Host "Signing in to tenant $TenantId via service connection $($conn.ServiceConnectionId)"
    $assertion = Get-PipelineOidcToken -ServiceConnectionId $conn.ServiceConnectionId
    try {
        $null = Connect-AzAccount -ServicePrincipal -ApplicationId $conn.ClientId -Tenant $TenantId `
            -FederatedToken $assertion -Scope Process -WarningAction SilentlyContinue
    } catch {
        # Connect-AzAccount reports any token failure as "Could not find tenant id for
        # provided tenant domain", which hides the Entra error. Print the AADSTS error
        # before rethrowing, or the failure is undiagnosable from the ADO log.
        Write-FederationDiagnostics -TenantId $TenantId -ClientId $conn.ClientId -Assertion $assertion
        throw
    }
}

function Write-FederationDiagnostics {
    # Replays the sign-in against the Entra token endpoint purely to print its error body.
    param([string] $TenantId, [string] $ClientId, [string] $Assertion)
    try {
        $null = Invoke-RestMethod -Method POST -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" -Body @{
            grant_type            = 'client_credentials'
            client_id             = $ClientId
            scope                 = 'https://management.azure.com/.default'
            client_assertion_type = 'urn:ietf:params:oauth:client-assertion-type:jwt-bearer'
            client_assertion      = $Assertion
        }
    } catch {
        if ($_.PSObject.Properties.Name -contains 'ErrorDetails' -and $_.ErrorDetails) {
            Write-Host "  Entra token error: $($_.ErrorDetails.Message)"
        }
    }
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
    param([object[]] $Rows, [Parameter(Mandatory)][string] $DefaultTenantId)
    if (-not $Rows -or $Rows.Count -eq 0) { throw "CSV is empty." }

    $required = @('TenantId', 'SubscriptionName', 'ResourceGroupName') + $script:ManagedKeys
    $present = $Rows[0].PSObject.Properties.Name
    foreach ($col in $required) {
        if ($present -notcontains $col) { throw "CSV is missing required column: $col" }
    }

    # Nested index: $index[<tenantId>][<subName>][<rgName>] = @{ tagKey = normalizedValue }
    $index = @{}
    $skippedRows = 0
    $defaultedRows = 0
    $rowNumber = 1   # header is row 1; data rows start at 2
    foreach ($row in $Rows) {
        $rowNumber++
        $tenantId = "$($row.TenantId)".Trim().ToLowerInvariant()
        $subName  = "$($row.SubscriptionName)".Trim().ToLowerInvariant()
        $rgName   = "$($row.ResourceGroupName)".Trim().ToLowerInvariant()
        # A blank TenantId means the home tenant. Rows written before the CSV had a
        # TenantId column all belong there, and the sync task MUST apply the same
        # rule or it appends a second, tenant-qualified row for every one of them.
        if (-not $tenantId) { $tenantId = $DefaultTenantId; $defaultedRows++ }
        if (-not $subName -or -not $rgName) {
            Write-Warning "CSV row $rowNumber skipped - missing SubscriptionName or ResourceGroupName (SubscriptionName='$($row.SubscriptionName)', ResourceGroupName='$($row.ResourceGroupName)')."
            $skippedRows++
            continue
        }

        $desired = @{}
        foreach ($k in $script:ManagedKeys) {
            $normalized = ConvertTo-NormalizedTagValue -Value $row.$k
            if ($null -ne $normalized) { $desired[$k] = $normalized }
        }

        if (-not $index.ContainsKey($tenantId)) { $index[$tenantId] = @{} }
        if (-not $index[$tenantId].ContainsKey($subName)) { $index[$tenantId][$subName] = @{} }
        if ($index[$tenantId][$subName].ContainsKey($rgName)) {
            Write-Warning "CSV row $rowNumber duplicates an earlier row for '$($row.SubscriptionName)' / '$($row.ResourceGroupName)' in tenant $tenantId - this later row wins."
        }
        $index[$tenantId][$subName][$rgName] = $desired
    }
    if ($skippedRows -gt 0) {
        Write-Host "New-CsvIndex: $skippedRows row(s) skipped due to missing SubscriptionName or ResourceGroupName."
    }
    if ($defaultedRows -gt 0) {
        Write-Host "New-CsvIndex: $defaultedRows row(s) have a blank TenantId and were treated as home tenant $DefaultTenantId."
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
        # Normalize BOTH sides identically before compare - same whitespace-strip +
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
    # Plain -replace rather than WebUtility::HtmlEncode - no .NET overload resolution.
    # '&' must be first or it would double-encode the entities added after it.
    return ($Value -replace '&', '&amp;' -replace '<', '&lt;' -replace '>', '&gt;' -replace '"', '&quot;')
}

function New-ReconciliationHtmlReport {
    param(
        [Parameter(Mandatory)] $Stats,
        [Parameter()][AllowEmptyCollection()][object[]] $Results = @(),
        [Parameter(Mandatory)][string] $TenantScopes,
        [Parameter(Mandatory)][string] $CsvSource
    )

    # Only live runs reach the mail step, so the report always describes written changes.
    $changed = @($Results | Where-Object { $_.Changes.Count -gt 0 })

    $th = 'style="text-align:left;padding:6px 10px;border:1px solid #d0d7de;background:#f3f5f7;font-weight:600;"'
    $td = 'style="text-align:left;padding:6px 10px;border:1px solid #d0d7de;"'

    $runTime = Get-Date -Date ([datetime]::UtcNow) -Format 'yyyy-MM-dd HH:mm:ss'

    # Plain string list + -join rather than StringBuilder: Append() has ~30 overloads
    # and resolving them is a needless failure surface here.
    $html = New-Object System.Collections.Generic.List[object]
    $html.Add('<html><body style="font-family:Segoe UI,Arial,sans-serif;font-size:14px;color:#24292f;">')
    $html.Add('<h2 style="margin:0 0 4px 0;">Azure resource-group tag reconciliation</h2>')
    $html.Add('<p style="margin:0 0 16px 0;color:#0b6b34;font-weight:600;">LIVE - tags were merged</p>')

    $html.Add('<table style="border-collapse:collapse;margin-bottom:20px;">')
    $html.Add("<tr><td $td>Run (UTC)</td><td $td>$runTime</td></tr>")
    $html.Add("<tr><td $td>Tenant = management group</td><td $td>$(ConvertTo-HtmlText $TenantScopes)</td></tr>")
    $html.Add("<tr><td $td>CSV source</td><td $td>$(ConvertTo-HtmlText $CsvSource)</td></tr>")
    $html.Add('</table>')

    $html.Add('<h3 style="margin:0 0 8px 0;">Summary</h3>')
    $html.Add('<table style="border-collapse:collapse;margin-bottom:20px;">')
    $html.Add("<tr><th $th>Metric</th><th $th>Count</th></tr>")
    # GetEnumerator, not $Stats[$key] - OrderedDictionary exposes both Item[int]
    # and Item[object], so indexing it is the ambiguous form, not the safe one.
    foreach ($entry in $Stats.GetEnumerator()) {
        $html.Add("<tr><td $td>$(ConvertTo-HtmlText $entry.Key)</td><td $td>$($entry.Value)</td></tr>")
    }
    $html.Add('</table>')

    $html.Add("<h3 style=""margin:0 0 8px 0;"">Changed ($($changed.Count) resource group(s))</h3>")
    if ($changed.Count -eq 0) {
        $html.Add('<p>No tag differences found - every matched resource group already agrees with the CSV.</p>')
    } else {
        $html.Add('<table style="border-collapse:collapse;">')
        # One row per resource group, one column per managed tag key. A changed key
        # shows "current -> CSV value"; a key that already matched shows a dash.
        $header = "<tr><th $th>Tenant</th><th $th>Subscription</th><th $th>Resource group</th>"
        foreach ($key in $script:ManagedKeys) { $header += "<th $th>$(ConvertTo-HtmlText $key)<br>current &rarr; CSV value</th>" }
        $html.Add($header + '</tr>')
        foreach ($result in $changed) {
            $byKey = @{}
            foreach ($change in $result.Changes) { $byKey[$change.Key] = $change }
            $row = "<tr><td $td>$(ConvertTo-HtmlText $result.TenantId)</td>" +
                   "<td $td>$(ConvertTo-HtmlText $result.SubscriptionName)</td>" +
                   "<td $td>$(ConvertTo-HtmlText $result.ResourceGroupName)</td>"
            foreach ($key in $script:ManagedKeys) {
                if ($byKey.ContainsKey($key)) {
                    $row += "<td $td>$(ConvertTo-HtmlText $byKey[$key].From) &rarr; <b>$(ConvertTo-HtmlText $byKey[$key].To)</b></td>"
                } else {
                    $row += "<td $td><span style=""color:#888;"">&ndash;</span></td>"
                }
            }
            $html.Add($row + '</tr>')
        }
        $html.Add('</table>')
    }

    $html.Add('<p style="margin-top:24px;color:#57606a;font-size:12px;">Generated by Invoke-TagReconciliation.ps1. The SharePoint CSV is the source of truth - correct values there, not in Azure.</p>')
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
    try {
        # sendMail returns 202 with an empty body; swallow it so nothing leaks to the pipeline.
        $null = Invoke-RestMethod -Method POST -Uri $uri `
            -Headers @{ Authorization = "Bearer $token" } `
            -ContentType 'application/json; charset=utf-8' `
            -Body ([System.Text.Encoding]::UTF8.GetBytes($json))
    } catch {
        # Invoke-RestMethod's message is only "Response status code does not indicate
        # success: 404 (Not Found)." - the Graph error code that says WHY is in the
        # response body. Print it, or the failure is undiagnosable from the ADO log.
        if ($_.PSObject.Properties.Name -contains 'ErrorDetails' -and $_.ErrorDetails) {
            Write-Host "Graph sendMail error (sender '$From'): $($_.ErrorDetails.Message)"
        }
        throw
    }
}

# --- main --------------------------------------------------------------------

# @() at the call site - the function's output unrolls (see Resolve-MailRecipients below).
$scopes = @(Resolve-TenantScopes -Value $TenantScopes)
if ($scopes.Count -eq 0) { throw "TenantScopes is empty. Expected '<tenantId>=<managementGroupId>[;...]'." }
$scopeLabel = ($scopes | ForEach-Object { "$($_.TenantId) = $($_.ManagementGroupId)" }) -join '; '

# The AzurePowerShell task signs in as the home tenant's UAMI, and that login is kept
# so the script can return to it. SharePoint and the report mailbox live there, so every Graph call is
# made as this identity. Other tenants are entered as their own UAMI.
$script:HomeContext = Get-AzContext
if (-not $script:HomeContext -or -not $script:HomeContext.Tenant) { throw "No Az context - the script must run signed in to the home tenant." }
$script:HomeTenantId = "$($script:HomeContext.Tenant.Id)".ToLowerInvariant()
$homeTenantId = $script:HomeTenantId
Write-Host "Home tenant: $homeTenantId"
Write-Host "Tenant scopes: $scopeLabel"

# Fail before doing any work if a tenant has no way to be signed in to.
# Not $script:TenantConnections: at script scope that IS the [string] parameter, and
# assigning the hashtable to it would turn it back into a string.
$script:TenantConnectionMap = Resolve-TenantConnections -Value $TenantConnections
foreach ($scope in $scopes) {
    if ($scope.TenantId -ne $homeTenantId -and -not $script:TenantConnectionMap.ContainsKey($scope.TenantId)) {
        throw "Tenant $($scope.TenantId) is in TenantScopes but is not the home tenant and has no TenantConnections entry."
    }
}

$csvSource = "https://$SharePointHostname$SharePointSitePath/$CsvItemPath"
Write-Host "Reading CSV from SharePoint: $csvSource"
$rows = Get-CsvFromSharePoint -Hostname $SharePointHostname -SitePath $SharePointSitePath -ItemPath $CsvItemPath
Write-Host "CSV rows: $($rows.Count)"

$csvIndex = New-CsvIndex -Rows $rows -DefaultTenantId $homeTenantId
$totalSubs = 0
$totalRules = 0
foreach ($tenantRules in $csvIndex.Values) {
    $totalSubs += $tenantRules.Count
    foreach ($subRules in $tenantRules.Values) { $totalRules += $subRules.Count }
}
Write-Host "CSV tenants: $($csvIndex.Count); subscriptions: $totalSubs; total (tenant, sub, RG) rules: $totalRules"

# Rows for a tenant that isn't configured can never be applied - say so rather than
# leaving them to drop out silently.
$scopedTenantIds = @($scopes | ForEach-Object { $_.TenantId })
foreach ($csvTenantId in $csvIndex.Keys) {
    if ($scopedTenantIds -notcontains $csvTenantId) {
        Write-Warning "CSV has rows for TenantId '$csvTenantId', which is not in TenantScopes - those rows are ignored."
    }
}

$stats = [ordered]@{
    tenantsInspected = 0
    tenantsSkipped   = 0
    tenantsFailed    = 0
    subsInspected    = 0
    subsMatched      = 0
    subsSkipped      = 0
    rgsInspected     = 0
    rgsMatched       = 0
    rgsUpdated       = 0
    rgsUnchanged     = 0
}

$results = New-Object System.Collections.Generic.List[object]

foreach ($scope in $scopes) {
    $stats.tenantsInspected++
    Write-Host ""
    Write-Host "##### Tenant: $($scope.TenantId) (management group '$($scope.ManagementGroupId)') #####"

    if (-not $csvIndex.ContainsKey($scope.TenantId)) {
        Write-Host "  skipped - TenantId '$($scope.TenantId)' not in CSV"
        $stats.tenantsSkipped++
        continue
    }
    $tenantRules = $csvIndex[$scope.TenantId]

    # A tenant that can't be signed in to or listed (app not consented there, no Reader
    # on the MG) is skipped with a warning, the same way an unreachable subscription
    # is - one broken tenant must not block the others.
    try {
        Connect-Tenant -TenantId $scope.TenantId
        $subs = @(Get-SubscriptionsUnderManagementGroup -ManagementGroupId $scope.ManagementGroupId)
    } catch {
        Write-Warning "Skipping tenant $($scope.TenantId) - sign-in or subscription listing failed: $($_.Exception.Message)"
        $stats.tenantsFailed++
        continue
    }
    Write-Host "Subscriptions under MG '$($scope.ManagementGroupId)': $($subs.Count)"

    foreach ($sub in $subs) {
        $stats.subsInspected++
        Write-Host ""
        Write-Host "=== Subscription: $($sub.Name) ($($sub.Id)) ==="

        $subKey = "$($sub.Name)".Trim().ToLowerInvariant()
        if (-not $tenantRules.ContainsKey($subKey)) {
            Write-Host "  skipped - SubscriptionName '$($sub.Name)' not in CSV for this tenant"
            $stats.subsSkipped++
            continue
        }
        $stats.subsMatched++
        $rgRules = $tenantRules[$subKey]

        try {
            $null = Set-AzContext -SubscriptionId $sub.Id -Tenant $scope.TenantId -WarningAction SilentlyContinue
        } catch {
            Write-Warning "Skipping $($sub.Name) ($($sub.Id)) - Set-AzContext failed: $($_.Exception.Message)"
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
                TenantId          = $scope.TenantId
                SubscriptionName  = $sub.Name
                ResourceGroupName = $rg.ResourceGroupName
                Changes           = $sync.Changes
            })

            if ($sync.Changes.Count -gt 0) { $stats.rgsUpdated++ } else { $stats.rgsUnchanged++ }
        }
    }
}

Write-Host ""
Write-Host "Done. WhatIfMode=$WhatIfMode"
Write-Host ("Summary: tenants inspected={0}, skipped={1}, failed={2} | subs inspected={3}, matched={4}, skipped={5} | rgs inspected={6}, matched={7}, updated={8}, unchanged={9}" -f `
    $stats.tenantsInspected, $stats.tenantsSkipped, $stats.tenantsFailed, `
    $stats.subsInspected, $stats.subsMatched, $stats.subsSkipped, `
    $stats.rgsInspected, $stats.rgsMatched, $stats.rgsUpdated, $stats.rgsUnchanged)

# --- HTML report --------------------------------------------------------------
# Only reached when the reconciliation above completed without throwing, so the
# report always describes a successful run. Dry runs (WhatIfMode) send nothing;
# only live runs mail the report.

if ($WhatIfMode) {
    Write-Host ""
    Write-Host "Email report skipped - WhatIfMode is on (dry run)."
    return
}

# @() at the call site, not a wrapped return: the function's output unrolls, so an
# empty recipient list has to be re-collected here or $recipients would be $null.
$recipients = @(Resolve-MailRecipients -Addresses $MailTo)

if ($recipients.Count -eq 0) {
    Write-Host ""
    Write-Host "Email report skipped - no MailTo recipients configured."
    return
}
if ([string]::IsNullOrWhiteSpace($MailFrom)) {
    throw "MailTo was supplied but MailFrom is empty. Graph app-only sendMail needs a sender mailbox (UPN or object id)."
}

$html = New-ReconciliationHtmlReport `
    -Stats $stats `
    -Results $results `
    -TenantScopes $scopeLabel `
    -CsvSource $csvSource

# "LIVE" stays in the subject so existing inbox rules keyed on it keep matching.
$subject = "{0} - LIVE - {1} RG(s) changed" -f $MailSubject, $stats.rgsUpdated

Write-Host ""
# The mailbox is in the home tenant; the loop above may have left another tenant active.
Connect-Tenant -TenantId $homeTenantId
Write-Host "Sending report to $($recipients.Count) recipient(s): $($recipients -join ', ')"
Send-GraphMailReport -From $MailFrom -To $recipients -Subject $subject -HtmlBody $html
Write-Host "Report sent."
