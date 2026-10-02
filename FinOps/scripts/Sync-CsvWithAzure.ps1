#Requires -Version 7.0
#Requires -Modules Az.Accounts, Az.Resources

<#
.SYNOPSIS
Ensure the tags CSV in SharePoint has a row for every (Tenant, Subscription,
ResourceGroup) currently present under each configured tenant's management group -
the same app registration is signed in to each tenant in turn. Existing rows are NEVER
modified; missing pairs are appended, seeded with the RG's current tag values on
the four managed keys (so humans see reality and can correct as needed).

.DESCRIPTION
  - Read the CSV from SharePoint via Microsoft Graph and capture the drive item's ETag.
  - For each tenant in -TenantScopes: sign the app registration (-AppClientId) in to
    it with a fresh Azure DevOps OIDC token for the service connection,
    enumerate every subscription under its management group, then Set-AzContext +
    Get-AzResourceGroup in each to build the actual (tenant, sub, RG) set. Unlike
    the reconciliation task, this one has to look at every tenant and subscription -
    the whole point is to discover ones not yet in the CSV.
  - Compute the (tenant, sub, RG) entries that are in Azure but not the CSV.
  - Append one row per missing entry, populating TenantId, SubscriptionName, SubscriptionId
    (if that column exists), ResourceGroupName, and - for each of the four managed
    tag keys - the RG's current tag value on that key (raw, as stored in Azure)
    or an empty cell if the RG has no such tag. Seeding from the RG rather than
    leaving blank means the CSV reflects the real starting state
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

.PARAMETER TenantScopes
The tenants to scan and the management group to scan in each, as
"<tenantId>=<managementGroupName>" entries separated by ';' or ','. One entry per tenant.

.PARAMETER AppClientId
Application (client) id of the multi-tenant app registration that does the work.
It must have a federated credential for the Azure DevOps service connection.

.PARAMETER WhatIfMode
When $true (default), log the rows that would be added but do not PUT the CSV back.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $SharePointHostname,
    [Parameter(Mandatory)] [string] $SharePointSitePath,
    [Parameter(Mandatory)] [string] $CsvItemPath,
    [Parameter(Mandatory)] [string] $TenantScopes,
    [Parameter(Mandatory)] [string] $AppClientId,
    [Parameter()]          [bool]   $WhatIfMode = $true
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$script:ManagedKeys      = @('BusinessUnit', 'CostObject', 'GeneralLedgerCode', 'FinancialDelegate')
$script:RequiredColumns  = @('TenantId', 'SubscriptionName', 'ResourceGroupName') + $script:ManagedKeys

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

function Get-PipelineOidcToken {
    # Ask Azure DevOps for a fresh OIDC token for the service connection. The token
    # names the service connection (issuer + subject), not the UAMI behind it, and the
    # app registration has a federated credential trusting exactly that. A token for
    # the UAMI itself cannot be used here: Entra rejects a token obtained through one
    # federated credential as the assertion for another (AADSTS700231).
    $requestUri   = $env:SYSTEM_OIDCREQUESTURI
    $connectionId = $env:AZURESUBSCRIPTION_SERVICE_CONNECTION_ID
    $systemToken  = $env:SYSTEM_ACCESSTOKEN
    if (-not $requestUri -or -not $connectionId -or -not $systemToken) {
        throw ("Cannot sign in as the app registration: SYSTEM_OIDCREQUESTURI, AZURESUBSCRIPTION_SERVICE_CONNECTION_ID " +
               "and SYSTEM_ACCESSTOKEN must all be set. The first two come from the AzurePowerShell task; " +
               "SYSTEM_ACCESSTOKEN must be mapped in the task's env: block.")
    }
    $uri  = "${requestUri}?api-version=7.1&serviceConnectionId=$connectionId"
    $resp = Invoke-RestMethod -Method POST -Uri $uri `
        -Headers @{ Authorization = "Bearer $systemToken" } `
        -ContentType 'application/json'
    return $resp.oidcToken
}

function Connect-Tenant {
    # Make the app registration, signed in to $TenantId, the default Az context.
    # No-op when it already is, unless -Fresh: the Azure DevOps token is short-lived,
    # so a sign-in made early in the run cannot be relied on to fetch a new token for
    # another resource (Graph) at the end of it.
    param([Parameter(Mandatory)][string] $TenantId, [switch] $Fresh)
    $ctx = Get-AzContext
    if (-not $Fresh -and $ctx -and $ctx.Tenant -and $ctx.Account -and
        "$($ctx.Tenant.Id)" -eq $TenantId -and "$($ctx.Account.Id)" -eq $AppClientId) { return }

    Write-Host "Signing in to tenant $TenantId as app registration $AppClientId (federated via the service connection)"
    $assertion = Get-PipelineOidcToken
    try {
        $null = Connect-AzAccount -ServicePrincipal -ApplicationId $AppClientId -Tenant $TenantId `
            -FederatedToken $assertion -Scope Process -WarningAction SilentlyContinue
    } catch {
        # Connect-AzAccount reports any token failure as "Could not find tenant id for
        # provided tenant domain", which hides the Entra error. Replay the same exchange
        # against the token endpoint so the AADSTS code lands in the log, then rethrow.
        Write-FederationDiagnostics -TenantId $TenantId -Assertion $assertion
        throw
    }
}

function Write-FederationDiagnostics {
    param([string] $TenantId, [string] $Assertion)
    try {
        # iss / sub / aud are what the app registration's federated credential must
        # match. They identify the service connection and are not secret; the token itself is not printed.
        $payload = ($Assertion -split '\.')[1].Replace('-', '+').Replace('_', '/')
        while ($payload.Length % 4) { $payload += '=' }
        $claims = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($payload)) | ConvertFrom-Json
        foreach ($name in @('iss', 'sub', 'aud', 'idtyp', 'ver')) {
            if ($claims.PSObject.Properties.Name -contains $name) { Write-Host "  assertion ${name}: $($claims.$name)" }
        }
    } catch {
        Write-Host "  could not decode the assertion: $($_.Exception.Message)"
    }
    try {
        $null = Invoke-RestMethod -Method POST -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" -Body @{
            grant_type            = 'client_credentials'
            client_id             = $AppClientId
            scope                 = 'https://management.azure.com/.default'
            client_assertion_type = 'urn:ietf:params:oauth:client-assertion-type:jwt-bearer'
            client_assertion      = $Assertion
        }
        Write-Host "  token endpoint accepted the assertion - the failure is inside Connect-AzAccount, not Entra."
    } catch {
        if ($_.PSObject.Properties.Name -contains 'ErrorDetails' -and $_.ErrorDetails) {
            Write-Host "  Entra token error: $($_.ErrorDetails.Message)"
        } else {
            Write-Host "  Entra token request failed: $($_.Exception.Message)"
        }
    }
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
    # Nested hashtable: $set[<tenantId lower>][<subName lower>][<rgName lower>] = $true.
    # Rows with any match key blank cannot claim an RG unambiguously, so they
    # are ignored - the reconciliation task warns about them separately.
    param([object[]] $Rows)
    $set = @{}
    foreach ($row in $Rows) {
        $tenantKey = "$($row.TenantId)".Trim().ToLowerInvariant()
        $subKey    = "$($row.SubscriptionName)".Trim().ToLowerInvariant()
        $rgKey     = "$($row.ResourceGroupName)".Trim().ToLowerInvariant()
        if (-not $tenantKey -or -not $subKey -or -not $rgKey) { continue }
        if (-not $set.ContainsKey($tenantKey)) { $set[$tenantKey] = @{} }
        if (-not $set[$tenantKey].ContainsKey($subKey)) { $set[$tenantKey][$subKey] = @{} }
        $set[$tenantKey][$subKey][$rgKey] = $true
    }
    return $set
}

# --- main --------------------------------------------------------------------

# @() at the call site - the function's output unrolls.
$scopes = @(Resolve-TenantScopes -Value $TenantScopes)
if ($scopes.Count -eq 0) { throw "TenantScopes is empty. Expected '<tenantId>=<managementGroupId>[;...]'." }

# The AzurePowerShell task signs in as the UAMI in the home tenant. The UAMI does none
# of the work; its login only tells us which tenant is home. SharePoint lives in the home tenant, so the CSV GET and PUT
# both run as the app registration signed in there.
$taskContext = Get-AzContext
if (-not $taskContext -or -not $taskContext.Tenant) { throw "No Az context - the script must run signed in to the home tenant." }
$homeTenantId = "$($taskContext.Tenant.Id)".ToLowerInvariant()
Write-Host "Home tenant: $homeTenantId"
Write-Host "Tenant scopes: $(($scopes | ForEach-Object { "$($_.TenantId) = $($_.ManagementGroupId)" }) -join '; ')"
Connect-Tenant -TenantId $homeTenantId

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
$existingSubCount = 0
$existingRgCount  = 0
foreach ($tenantSet in $existing.Values) {
    $existingSubCount += $tenantSet.Count
    foreach ($subSet in $tenantSet.Values) { $existingRgCount += $subSet.Count }
}
Write-Host "CSV covers $($existing.Count) tenant(s), $existingSubCount subscription(s), $existingRgCount (tenant, sub, RG) row(s)."

$stats = [ordered]@{
    tenantsInspected = 0
    tenantsFailed    = 0
    subsInspected    = 0
    subsFailed       = 0
    rgsInspected     = 0
    rgsAlready       = 0
    rgsToAppend      = 0
}

$newRows = New-Object System.Collections.Generic.List[object]

foreach ($scope in $scopes) {
    $stats.tenantsInspected++
    Write-Host ""
    Write-Host "##### Tenant: $($scope.TenantId) (management group '$($scope.ManagementGroupId)') #####"

    # A tenant that can't be signed in to or listed is skipped with a warning; its RGs
    # simply aren't appended this run. One broken tenant must not block the others.
    try {
        Connect-Tenant -TenantId $scope.TenantId
        $subs = @(Get-SubscriptionsUnderManagementGroup -ManagementGroupId $scope.ManagementGroupId)
    } catch {
        Write-Warning "Skipping tenant $($scope.TenantId) - sign-in or subscription listing failed: $($_.Exception.Message)"
        $stats.tenantsFailed++
        continue
    }
    Write-Host "Subscriptions under MG '$($scope.ManagementGroupId)': $($subs.Count)"

    $existingForTenant = if ($existing.ContainsKey($scope.TenantId)) { $existing[$scope.TenantId] } else { @{} }

    foreach ($sub in $subs) {
        $stats.subsInspected++
        Write-Host ""
        Write-Host "=== Subscription: $($sub.Name) ($($sub.Id)) ==="

        try {
            $null = Set-AzContext -SubscriptionId $sub.Id -Tenant $scope.TenantId -WarningAction SilentlyContinue
        } catch {
            Write-Warning "Skipping $($sub.Name) ($($sub.Id)) - Set-AzContext failed: $($_.Exception.Message)"
            $stats.subsFailed++
            continue
        }

        $rgs = Get-AzResourceGroup
        $subKey = "$($sub.Name)".Trim().ToLowerInvariant()
        $existingForSub = if ($existingForTenant.ContainsKey($subKey)) { $existingForTenant[$subKey] } else { @{} }

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
                    'TenantId'          { $rowObj[$col] = $scope.TenantId }
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
            Write-Host "  + will append: $($scope.TenantId) / $($sub.Name) / $($rg.ResourceGroupName)$seedNote"
        }
    }
}

Write-Host ""
Write-Host ("Summary: tenants inspected={0}, failed={1} | subs inspected={2}, failed={3} | rgs inspected={4}, already in CSV={5}, to append={6}" -f `
    $stats.tenantsInspected, $stats.tenantsFailed, $stats.subsInspected, $stats.subsFailed, `
    $stats.rgsInspected, $stats.rgsAlready, $stats.rgsToAppend)

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

# SharePoint is in the home tenant; the loop above may have left another tenant active.
Connect-Tenant -TenantId $homeTenantId -Fresh
Set-SharePointCsv -SiteId $csv.SiteId -EncodedPath $csv.EncodedPath -ETag $csv.ETag -Content $csvText
Write-Host "Uploaded updated CSV: +$($newRows.Count) row(s), total rows now $($combined.Count)."
