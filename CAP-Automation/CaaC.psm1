#Requires -Version 7.2
#Requires -Modules Microsoft.Graph.Authentication

<#
    CaaC.psm1 - Conditional Access as Code
    Deliberately uses Invoke-MgGraphRequest rather than the typed Graph SDK cmdlets,
    so that the JSON in /policies is the literal Graph request body. That means new
    Entra CA features work the day they ship, with no module upgrade required.
#>

Set-StrictMode -Version Latest

$script:GraphBase   = 'https://graph.microsoft.com/v1.0'
$script:PolicyUri   = "$script:GraphBase/identity/conditionalAccess/policies"
$script:LookupCache = @{}

#region Connection -------------------------------------------------------------

function Connect-CaaC {
    <#
    .SYNOPSIS
        Establishes a Graph connection for the toolkit.
    .PARAMETER Method
        AzureDevOps  - reuses the Az context established by the AzurePowerShell@5 task
                       (workload identity federation). No secrets involved.
        Interactive  - delegated sign-in, for local authoring and dry runs.
        ClientSecret - fallback for non-ADO automation. Avoid where WIF is possible.
    #>
    [CmdletBinding()]
    param(
        [ValidateSet('AzureDevOps', 'Interactive', 'ClientSecret')]
        [string] $Method = 'AzureDevOps',

        [string] $TenantId,
        [string] $ClientId,
        [string] $ClientSecret
    )

    switch ($Method) {
        'AzureDevOps' {
            if (-not (Get-Command Get-AzAccessToken -ErrorAction SilentlyContinue)) {
                throw 'Az.Accounts is not loaded. Run this inside an AzurePowerShell@5 task.'
            }
            $tokenParams = @{ ResourceUrl = 'https://graph.microsoft.com' }
            if ((Get-Command Get-AzAccessToken).Parameters.ContainsKey('AsSecureString')) {
                $tokenParams['AsSecureString'] = $true
                $token = (Get-AzAccessToken @tokenParams).Token
            }
            else {
                $token = ConvertTo-SecureString (Get-AzAccessToken @tokenParams).Token -AsPlainText -Force
            }
            Connect-MgGraph -AccessToken $token -NoWelcome
        }
        'Interactive' {
            $scopes = @(
                'Policy.Read.All'
                'Policy.ReadWrite.ConditionalAccess'
                'Application.Read.All'
                'Group.Read.All'
                'RoleManagement.Read.Directory'
            )
            Connect-MgGraph -Scopes $scopes -TenantId $TenantId -NoWelcome
        }
        'ClientSecret' {
            $cred = [pscredential]::new($ClientId, (ConvertTo-SecureString $ClientSecret -AsPlainText -Force))
            Connect-MgGraph -TenantId $TenantId -ClientSecretCredential $cred -NoWelcome
        }
    }

    $ctx = Get-MgContext
    if (-not $ctx) { throw 'Failed to establish a Microsoft Graph connection.' }
    Write-Host "Connected to tenant $($ctx.TenantId) as $($ctx.ClientId ?? $ctx.Account)"
    $script:LookupCache = @{}
    return $ctx
}

function Invoke-CaaCGraph {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Uri,
        [ValidateSet('GET', 'POST', 'PATCH', 'DELETE')] [string] $Method = 'GET',
        [hashtable] $Body
    )

    $params = @{ Uri = $Uri; Method = $Method; OutputType = 'Hashtable'; ErrorAction = 'Stop' }
    if ($PSBoundParameters.ContainsKey('Body')) {
        $params['Body']        = ($Body | ConvertTo-Json -Depth 30 -Compress)
        $params['ContentType'] = 'application/json'
    }

    # Graph throttles hard on bulk policy work. Retry on 429 / 5xx with backoff.
    for ($attempt = 1; $attempt -le 5; $attempt++) {
        try {
            return Invoke-MgGraphRequest @params
        }
        catch {
            $status = $_.Exception.Response.StatusCode.value__
            if ($attempt -eq 5 -or $status -notin 429, 500, 502, 503, 504) { throw }
            $delay = [math]::Pow(2, $attempt)
            Write-Warning "Graph returned $status. Retrying in ${delay}s (attempt $attempt/5)."
            Start-Sleep -Seconds $delay
        }
    }
}

function Get-CaaCGraphCollection {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Uri)

    $results = [System.Collections.Generic.List[object]]::new()
    $next    = $Uri
    while ($next) {
        $page = Invoke-CaaCGraph -Uri $next
        if ($page.ContainsKey('value')) { $page.value | ForEach-Object { $results.Add($_) } }
        $next = if ($page.ContainsKey('@odata.nextLink')) { $page['@odata.nextLink'] } else { $null }
    }
    return $results
}

#endregion

#region Definitions ------------------------------------------------------------

function Get-CaaCDefinition {
    <#
    .SYNOPSIS
        Loads and shape-validates policy definition files from disk.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Path,
        [string[]] $PolicyId
    )

    $files = Get-ChildItem -Path $Path -Filter '*.json' -File | Sort-Object Name
    $defs  = foreach ($file in $files) {
        try   { $raw = Get-Content $file.FullName -Raw | ConvertFrom-Json -AsHashtable -Depth 30 }
        catch { throw "Definition '$($file.Name)' is not valid JSON: $($_.Exception.Message)" }

        foreach ($key in 'metadata', 'policy') {
            if (-not $raw.ContainsKey($key)) { throw "Definition '$($file.Name)' is missing the '$key' block." }
        }
        foreach ($key in 'id', 'description', 'owner', 'targetState') {
            if (-not $raw.metadata.ContainsKey($key)) { throw "Definition '$($file.Name)' metadata is missing '$key'." }
        }
        if (-not $raw.policy.ContainsKey('displayName')) { throw "Definition '$($file.Name)' has no policy.displayName." }
        if ($raw.policy.ContainsKey('state')) {
            throw "Definition '$($file.Name)' must not set policy.state. State is injected by the deployment ring."
        }
        if ($raw.metadata.targetState -notin 'enabled', 'disabled', 'enabledForReportingOnly') {
            throw "Definition '$($file.Name)' has an invalid metadata.targetState."
        }

        $raw['SourceFile'] = $file.Name
        $raw
    }

    if ($PolicyId) { $defs = $defs | Where-Object { $_.metadata.id -in $PolicyId } }
    return @($defs)
}

function Get-CaaCEnvironment {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Path)

    if (-not (Test-Path $Path)) { throw "Environment config not found: $Path" }
    $env = Get-Content $Path -Raw | ConvertFrom-Json -AsHashtable -Depth 20
    if (-not $env.ContainsKey('aliases'))   { $env['aliases']   = @{} }
    if (-not $env.ContainsKey('guardrails')) { $env['guardrails'] = @{} }
    return $env
}

#endregion

#region Token resolution -------------------------------------------------------

function Resolve-CaaCLookup {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Type,
        [Parameter(Mandatory)] [string] $Value
    )

    $cacheKey = "$Type|$Value"
    if ($script:LookupCache.ContainsKey($cacheKey)) { return $script:LookupCache[$cacheKey] }

    $escaped = $Value.Replace("'", "''")
    $result  = switch ($Type) {

        'group' {
            $hits = Get-CaaCGraphCollection "$script:GraphBase/groups?`$filter=displayName eq '$escaped'&`$select=id,displayName"
            Assert-SingleHit -Hits $hits -Type $Type -Value $Value
            $hits[0].id
        }

        'user' {
            # Accepts UPN or object ID.
            (Invoke-CaaCGraph -Uri "$script:GraphBase/users/$([uri]::EscapeDataString($Value))`?`$select=id").id
        }

        'role' {
            # includeRoles / excludeRoles take roleTemplateId, not the activated role's object ID.
            $all  = Get-CaaCGraphCollection "$script:GraphBase/directoryRoleTemplates"
            $hits = @($all | Where-Object { $_.displayName -eq $Value })
            Assert-SingleHit -Hits $hits -Type $Type -Value $Value
            $hits[0].id
        }

        'app' {
            # includeApplications / excludeApplications take the appId (client ID).
            $hits = Get-CaaCGraphCollection "$script:GraphBase/servicePrincipals?`$filter=displayName eq '$escaped'&`$select=appId,displayName"
            Assert-SingleHit -Hits $hits -Type $Type -Value $Value
            $hits[0].appId
        }

        'servicePrincipal' {
            # Workload identity policies take the service principal object ID.
            $hits = Get-CaaCGraphCollection "$script:GraphBase/servicePrincipals?`$filter=displayName eq '$escaped'&`$select=id,displayName"
            Assert-SingleHit -Hits $hits -Type $Type -Value $Value
            $hits[0].id
        }

        'namedLocation' {
            $all  = Get-CaaCGraphCollection "$script:GraphBase/identity/conditionalAccess/namedLocations"
            $hits = @($all | Where-Object { $_.displayName -eq $Value })
            Assert-SingleHit -Hits $hits -Type $Type -Value $Value
            $hits[0].id
        }

        'authStrength' {
            $all  = Get-CaaCGraphCollection "$script:GraphBase/policies/authenticationStrengthPolicies"
            $hits = @($all | Where-Object { $_.displayName -eq $Value })
            Assert-SingleHit -Hits $hits -Type $Type -Value $Value
            $hits[0].id
        }

        default { throw "Unknown token type '$Type'. Supported: group, user, role, app, servicePrincipal, namedLocation, authStrength." }
    }

    $script:LookupCache[$cacheKey] = $result
    Write-Verbose "Resolved {{${Type}:${Value}}} -> $result"
    return $result
}

function Assert-SingleHit {
    param($Hits, [string] $Type, [string] $Value)
    $count = @($Hits).Count
    if ($count -eq 0) { throw "Token {{${Type}:${Value}}} matched no object in this tenant." }
    if ($count -gt 1) { throw "Token {{${Type}:${Value}}} matched $count objects. Directory object names must be unique." }
}

function Resolve-CaaCToken {
    <#
    .SYNOPSIS
        Walks a policy body and replaces {{type:name}} tokens with tenant object IDs.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $InputObject,
        [hashtable] $Aliases = @{}
    )

    if ($null -eq $InputObject) { return $null }

    if ($InputObject -is [System.Collections.IDictionary]) {
        $out = @{}
        foreach ($key in $InputObject.Keys) {
            $out[$key] = Resolve-CaaCToken -InputObject $InputObject[$key] -Aliases $Aliases
        }
        return $out
    }

    if ($InputObject -isnot [string] -and $InputObject -is [System.Collections.IEnumerable]) {
        return @(foreach ($item in $InputObject) { Resolve-CaaCToken -InputObject $item -Aliases $Aliases })
    }

    if ($InputObject -is [string] -and $InputObject -match '^\{\{(?<type>[A-Za-z]+):(?<value>.+)\}\}$') {
        $type  = $Matches['type']
        $value = $Matches['value']

        # Environment aliases let one definition target different object names per tenant.
        $aliasKey = "${type}:${value}"
        if ($Aliases.ContainsKey($aliasKey)) {
            Write-Verbose "Alias $aliasKey -> $($Aliases[$aliasKey])"
            $value = $Aliases[$aliasKey]
        }
        return Resolve-CaaCLookup -Type $type -Value $value
    }

    return $InputObject
}

#endregion

#region Comparison -------------------------------------------------------------

function ConvertTo-CaaCCanonical {
    <#
    .SYNOPSIS
        Deterministic string form of an object: keys sorted, arrays treated as sets.
        CA policy arrays are unordered ID lists, so set semantics avoid false drift.
    #>
    param($InputObject)

    if ($null -eq $InputObject) { return 'null' }

    if ($InputObject -is [System.Collections.IDictionary]) {
        $parts = foreach ($key in ($InputObject.Keys | Sort-Object)) {
            '"{0}":{1}' -f $key, (ConvertTo-CaaCCanonical $InputObject[$key])
        }
        return '{' + ($parts -join ',') + '}'
    }

    if ($InputObject -isnot [string] -and $InputObject -is [System.Collections.IEnumerable]) {
        $parts = @(foreach ($item in $InputObject) { ConvertTo-CaaCCanonical $item }) | Sort-Object
        return '[' + ($parts -join ',') + ']'
    }

    if ($InputObject -is [bool]) { return $InputObject.ToString().ToLowerInvariant() }
    if ($InputObject -is [string]) { return '"' + $InputObject + '"' }
    return $InputObject.ToString()
}

function Get-CaaCProjection {
    <#
    .SYNOPSIS
        Reduces the live policy to only the properties the definition declares.
        Graph returns id, createdDateTime, templateId and null session controls that
        we never author, and comparing those would produce permanent phantom drift.
    #>
    param($Actual, $Desired)

    if ($Desired -is [System.Collections.IDictionary]) {
        if ($Actual -isnot [System.Collections.IDictionary]) { return $Actual }
        $out = @{}
        foreach ($key in $Desired.Keys) {
            $out[$key] = if ($Actual.Contains($key)) { Get-CaaCProjection -Actual $Actual[$key] -Desired $Desired[$key] } else { $null }
        }
        return $out
    }

    if ($Desired -isnot [string] -and $Desired -is [System.Collections.IEnumerable]) {
        $template = @($Desired) | Select-Object -First 1
        if ($template -is [System.Collections.IDictionary] -and $Actual) {
            return @(foreach ($item in $Actual) { Get-CaaCProjection -Actual $item -Desired $template })
        }
        return $Actual
    }

    return $Actual
}

function Compare-CaaCPolicy {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [hashtable] $Desired,
        [Parameter(Mandatory)] [hashtable] $Actual
    )

    $projected = Get-CaaCProjection -Actual $Actual -Desired $Desired
    $left      = ConvertTo-CaaCCanonical $Desired
    $right     = ConvertTo-CaaCCanonical $projected

    return [pscustomobject]@{
        InSync   = ($left -eq $right)
        Desired  = $left
        Observed = $right
    }
}

#endregion

#region Export -----------------------------------------------------------------

function Export-CaaCTenantState {
    <#
    .SYNOPSIS
        Snapshots every CA policy in the tenant. Run this before any write.
        CA policies have no soft delete, so this artifact is the only rollback path.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $OutputPath)

    $null     = New-Item -ItemType Directory -Path $OutputPath -Force
    $policies = Get-CaaCGraphCollection $script:PolicyUri
    $stamp    = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmssZ')

    $bundle = @{
        exportedUtc  = $stamp
        tenantId     = (Get-MgContext).TenantId
        policyCount  = @($policies).Count
        policies     = @($policies)
    }
    $bundlePath = Join-Path $OutputPath "ca-snapshot-$stamp.json"
    $bundle | ConvertTo-Json -Depth 30 | Set-Content $bundlePath -Encoding utf8

    # Per-policy files as well, so git diffs on the snapshot branch stay readable.
    $perPolicy = Join-Path $OutputPath 'policies'
    $null      = New-Item -ItemType Directory -Path $perPolicy -Force
    foreach ($policy in $policies) {
        $safeName = ($policy.displayName -replace '[^\w\-\.]', '_')
        $policy | ConvertTo-Json -Depth 30 | Set-Content (Join-Path $perPolicy "$safeName.json") -Encoding utf8
    }

    Write-Host "Exported $(@($policies).Count) policies to $bundlePath"
    return $bundlePath
}

#endregion

#region Deployment -------------------------------------------------------------

function Invoke-CaaCDeployment {
    <#
    .SYNOPSIS
        Reconciles repository definitions against the tenant.
    .PARAMETER Ring
        Plan       - no writes, prints the change set only.
        ReportOnly - new policies land in enabledForReportingOnly. Policies already
                     enforced in the tenant are NOT downgraded (see below).
        Enforce    - applies metadata.targetState.
    .PARAMETER ForceReportOnly
        Downgrades already-enforced policies to report-only. Only use this deliberately,
        e.g. to soak a significant change to a live policy.
    .NOTES
        The report-only ring must never demote a policy that is already enforced in the
        tenant. Once you adopt existing production policies, a routine main-branch build
        would otherwise turn off enforcement on every one of them. State is therefore
        decided after the live policy is read, not before.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [array]     $Definition,
        [Parameter(Mandatory)] [hashtable] $Environment,
        [Parameter(Mandatory)] [ValidateSet('Plan', 'ReportOnly', 'Enforce')] [string] $Ring,
        [switch] $AllowCreateInEnforce,
        [switch] $ForceReportOnly
    )

    $live    = Get-CaaCGraphCollection $script:PolicyUri
    $results = [System.Collections.Generic.List[object]]::new()

    foreach ($def in $Definition) {
        $id   = $def.metadata.id
        $body = Resolve-CaaCToken -InputObject $def.policy -Aliases $Environment.aliases

        $matches = @($live | Where-Object { $_.displayName -eq $body.displayName })
        if ($matches.Count -gt 1) {
            throw "Tenant has $($matches.Count) policies named '$($body.displayName)'. Resolve the duplicate manually before deploying."
        }
        $existing = $matches | Select-Object -First 1

        $body['state'] = Get-CaaCRingState -Ring $Ring -TargetState $def.metadata.targetState `
                                           -CurrentState $existing.state -ForceReportOnly:$ForceReportOnly

        Assert-CaaCBreakGlass -Body $body -Environment $Environment -PolicyId $id

        if (-not $existing) {
            if ($Ring -eq 'Enforce' -and -not $AllowCreateInEnforce) {
                throw "$id does not exist in the tenant. Deploy it through the ReportOnly ring first, or pass -AllowCreateInEnforce."
            }
            if ($Ring -eq 'Plan') {
                $results.Add([pscustomobject]@{ PolicyId = $id; Action = 'Create'; DisplayName = $body.displayName; State = $body.state; PolicyObjectId = $null })
                continue
            }
            $created = Invoke-CaaCGraph -Uri $script:PolicyUri -Method POST -Body $body
            Write-Host "CREATED $id -> $($created.id) [$($body.state)]"
            $results.Add([pscustomobject]@{ PolicyId = $id; Action = 'Create'; DisplayName = $body.displayName; State = $body.state; PolicyObjectId = $created.id })
            continue
        }

        $diff = Compare-CaaCPolicy -Desired $body -Actual $existing
        if ($diff.InSync) {
            Write-Host "NOCHANGE $id [$($existing.state)]"
            $results.Add([pscustomobject]@{ PolicyId = $id; Action = 'NoChange'; DisplayName = $body.displayName; State = $existing.state; PolicyObjectId = $existing.id })
            continue
        }

        if ($Ring -eq 'Plan') {
            Write-Host "UPDATE   $id"
            Write-Host "  desired : $($diff.Desired)"
            Write-Host "  observed: $($diff.Observed)"
            $results.Add([pscustomobject]@{ PolicyId = $id; Action = 'Update'; DisplayName = $body.displayName; State = $body.state; PolicyObjectId = $existing.id })
            continue
        }

        $null = Invoke-CaaCGraph -Uri "$script:PolicyUri/$($existing.id)" -Method PATCH -Body $body
        Write-Host "UPDATED  $id -> $($existing.id) [$($body.state)]"
        $results.Add([pscustomobject]@{ PolicyId = $id; Action = 'Update'; DisplayName = $body.displayName; State = $body.state; PolicyObjectId = $existing.id })
    }

    # Policies in the tenant that this repo does not own. Reported, never deleted.
    $ownedNames = $Definition | ForEach-Object { $_.policy.displayName }
    $unmanaged  = @($live | Where-Object { $_.displayName -notin $ownedNames })
    if ($unmanaged) {
        Write-Warning "$($unmanaged.Count) policies in the tenant are not managed by this repository:"
        $unmanaged | ForEach-Object { Write-Warning "  - $($_.displayName) [$($_.state)]" }
    }

    return $results
}

function Get-CaaCRingState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Ring,
        [Parameter(Mandatory)] [string] $TargetState,
        [string] $CurrentState,
        [switch] $ForceReportOnly
    )

    switch ($Ring) {
        'Plan'    { return $TargetState }
        'Enforce' { return $TargetState }
        'ReportOnly' {
            # A policy whose intended end state is 'disabled' is never switched on,
            # not even into report-only.
            if ($TargetState -eq 'disabled') { return 'disabled' }

            # Never demote a policy that is already enforcing in the tenant. This is
            # what makes adopting live production policies safe.
            if ($CurrentState -eq 'enabled' -and -not $ForceReportOnly) { return 'enabled' }

            return 'enabledForReportingOnly'
        }
    }
}

function Assert-CaaCBreakGlass {
    <#
    .SYNOPSIS
        Last line of defence, evaluated after token resolution against real object IDs.
        The offline Pester tests check the token is present; this checks it resolved to
        the group the environment actually nominated.
    #>
    param(
        [Parameter(Mandatory)] [hashtable] $Body,
        [Parameter(Mandatory)] [hashtable] $Environment,
        [Parameter(Mandatory)] [string]    $PolicyId
    )

    $guardrails = if ($Environment.ContainsKey('guardrails')) { $Environment['guardrails'] } else { @{} }
    $required   = if ($guardrails.Contains('requiredExclusionGroups')) { @($guardrails['requiredExclusionGroups']) } else { @() }
    if ($required.Count -eq 0) { return }

    $conditions = if ($Body.ContainsKey('conditions')) { $Body['conditions'] } else { @{} }
    $users      = if ($conditions.Contains('users')) { $conditions['users'] } else { @{} }

    $field = { param($name) if ($users.Contains($name)) { @($users[$name]) } else { @() } }

    $targetsEveryone = ('All' -in (& $field 'includeUsers')) -or
                       ((& $field 'includeRoles').Count  -gt 0) -or
                       ((& $field 'includeGroups').Count -gt 0)
    if (-not $targetsEveryone) { return }

    $excluded = (& $field 'excludeGroups') + (& $field 'excludeUsers')
    foreach ($token in $required) {
        $parts = $token -split ':', 2
        $value = if ($Environment['aliases'].Contains($token)) { $Environment['aliases'][$token] } else { $parts[1] }
        $objectId = Resolve-CaaCLookup -Type $parts[0] -Value $value
        if ($objectId -notin $excluded) {
            throw "$PolicyId does not exclude the required break-glass object '$value' ($objectId). Refusing to deploy."
        }
    }
}

#endregion

#region Import -----------------------------------------------------------------

function Get-CaaCTokenPathMap {
    <#
    .SYNOPSIS
        Which properties of a CA policy body hold directory object references, and
        what kind. Import uses this to reverse-resolve IDs into tokens.
    .NOTES
        Driven by path rather than by "does this look like a GUID", because several
        CA properties hold GUIDs that are not directory objects (external tenant IDs
        in includeGuestsOrExternalUsers, for one) and must be left alone.
    #>
    return [ordered]@{
        'conditions.users.includeUsers'                                       = 'user'
        'conditions.users.excludeUsers'                                       = 'user'
        'conditions.users.includeGroups'                                      = 'group'
        'conditions.users.excludeGroups'                                      = 'group'
        'conditions.users.includeRoles'                                       = 'role'
        'conditions.users.excludeRoles'                                       = 'role'
        'conditions.applications.includeApplications'                         = 'app'
        'conditions.applications.excludeApplications'                         = 'app'
        'conditions.applications.includeAuthenticationContextClassReferences' = 'authContext'
        'conditions.locations.includeLocations'                               = 'namedLocation'
        'conditions.locations.excludeLocations'                               = 'namedLocation'
        'conditions.clientApplications.includeServicePrincipals'              = 'servicePrincipal'
        'conditions.clientApplications.excludeServicePrincipals'              = 'servicePrincipal'
        'grantControls.authenticationStrength.id'                             = 'authStrength'
        'grantControls.termsOfUse'                                            = 'agreement'
    }
}

function Get-CaaCWellKnownValue {
    <#
    .SYNOPSIS
        Reserved keywords that Graph accepts in place of an object ID. Never tokenised.
    #>
    param([Parameter(Mandatory)] [string] $Type)

    $map = @{
        user             = @('All', 'None', 'GuestsOrExternalUsers')
        group            = @()
        role             = @()
        app              = @('All', 'None', 'Office365', 'MicrosoftAdminPortals')
        servicePrincipal = @('ServicePrincipalsInMyTenant', 'All', 'None')
        namedLocation    = @('All', 'AllTrusted')
        authContext      = @()
        authStrength     = @()
        agreement        = @()
    }
    return $map[$Type]
}

function Resolve-CaaCReverseLookup {
    <#
    .SYNOPSIS
        Turns a tenant object ID back into the display name a token would use.
    .DESCRIPTION
        Round-trips every lookup. A name is only usable as a token if resolving that
        name forward returns the same ID. Two groups sharing a display name would
        otherwise produce a definition that silently targets the wrong object in the
        next tenant, which is exactly the class of bug import is supposed to prevent.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Type,
        [Parameter(Mandatory)] [string] $Id
    )

    $cacheKey = "reverse|$Type|$Id"
    if ($script:LookupCache.ContainsKey($cacheKey)) { return $script:LookupCache[$cacheKey] }

    $result = [pscustomobject]@{ Type = $Type; Id = $Id; Name = $null; Verified = $false; Reason = $null }

    try {
        $name = switch ($Type) {
            'user'   { (Invoke-CaaCGraph -Uri "$script:GraphBase/users/$Id`?`$select=userPrincipalName").userPrincipalName }
            'group'  { (Invoke-CaaCGraph -Uri "$script:GraphBase/groups/$Id`?`$select=displayName").displayName }
            'role'   { (Invoke-CaaCGraph -Uri "$script:GraphBase/directoryRoleTemplates/$Id").displayName }
            'app'    { (Invoke-CaaCGraph -Uri "$script:GraphBase/servicePrincipals(appId='$Id')?`$select=displayName").displayName }
            'servicePrincipal' { (Invoke-CaaCGraph -Uri "$script:GraphBase/servicePrincipals/$Id`?`$select=displayName").displayName }
            'namedLocation'    { (Invoke-CaaCGraph -Uri "$script:GraphBase/identity/conditionalAccess/namedLocations/$Id").displayName }
            'authStrength'     { (Invoke-CaaCGraph -Uri "$script:GraphBase/policies/authenticationStrengthPolicies/$Id").displayName }
            'agreement'        { (Invoke-CaaCGraph -Uri "$script:GraphBase/identityGovernance/termsOfUse/agreements/$Id").displayName }
            'authContext'      { (Invoke-CaaCGraph -Uri "$script:GraphBase/identity/conditionalAccess/authenticationContextClassReferences/$Id").displayName }
            default { $null }
        }
    }
    catch {
        $result.Reason = "Graph lookup failed: $($_.Exception.Message.Split([Environment]::NewLine)[0])"
        $script:LookupCache[$cacheKey] = $result
        return $result
    }

    if (-not $name) {
        $result.Reason = 'Object exists but has no display name.'
        $script:LookupCache[$cacheKey] = $result
        return $result
    }

    $result.Name = $name

    try {
        $roundTrip = Resolve-CaaCLookup -Type $Type -Value $name
        if ($roundTrip -eq $Id) { $result.Verified = $true }
        else { $result.Reason = "Name '$name' resolves forward to $roundTrip, not $Id." }
    }
    catch {
        $result.Reason = "Name '$name' is not uniquely resolvable: $($_.Exception.Message.Split([Environment]::NewLine)[0])"
    }

    $script:LookupCache[$cacheKey] = $result
    return $result
}

function Remove-CaaCServerProperty {
    <#
    .SYNOPSIS
        Strips server-generated properties and null values from an exported policy.
        Empty arrays are kept: an explicitly empty exclusion list is authored intent.
    #>
    param($InputObject)

    $drop = @('id', 'createdDateTime', 'modifiedDateTime', 'deletedDateTime', 'templateId', '@odata.context')

    if ($InputObject -is [System.Collections.IDictionary]) {
        $out = @{}
        foreach ($key in $InputObject.Keys) {
            if ($key -in $drop) { continue }
            $value = $InputObject[$key]
            if ($null -eq $value) { continue }
            $clean = Remove-CaaCServerProperty $value
            if ($clean -is [System.Collections.IDictionary] -and $clean.Count -eq 0) { continue }
            $out[$key] = $clean
        }
        return $out
    }

    if ($InputObject -isnot [string] -and $InputObject -is [System.Collections.IEnumerable]) {
        return @(foreach ($item in $InputObject) { Remove-CaaCServerProperty $item })
    }

    return $InputObject
}

function ConvertTo-CaaCTokenisedBody {
    <#
    .SYNOPSIS
        Walks a policy body and replaces directory object IDs with tokens, guided by
        the path map. Anything that cannot be safely tokenised is left as a raw ID and
        recorded so a human sees it during review.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $InputObject,
        [string]    $Path = '',
        [hashtable] $ReverseAliases = @{},
        [Parameter(Mandatory)] [System.Collections.Generic.List[object]] $Unresolved
    )

    $map = Get-CaaCTokenPathMap

    if ($InputObject -is [System.Collections.IDictionary]) {
        $out = @{}
        foreach ($key in $InputObject.Keys) {
            $childPath = if ($Path) { "$Path.$key" } else { $key }
            $out[$key] = ConvertTo-CaaCTokenisedBody -InputObject $InputObject[$key] -Path $childPath `
                                                     -ReverseAliases $ReverseAliases -Unresolved $Unresolved
        }
        return $out
    }

    if ($InputObject -isnot [string] -and $InputObject -is [System.Collections.IEnumerable]) {
        # Array elements share the parent path; index is irrelevant to the map.
        return @(foreach ($item in $InputObject) {
            ConvertTo-CaaCTokenisedBody -InputObject $item -Path $Path -ReverseAliases $ReverseAliases -Unresolved $Unresolved
        })
    }

    if ($InputObject -isnot [string] -or -not $map.Contains($Path)) { return $InputObject }

    $type = $map[$Path]
    if ($InputObject -in (Get-CaaCWellKnownValue -Type $type)) { return $InputObject }

    $lookup = Resolve-CaaCReverseLookup -Type $type -Id $InputObject
    if (-not $lookup.Verified) {
        $Unresolved.Add([ordered]@{
            path   = $Path
            type   = $type
            value  = $InputObject
            name   = $lookup.Name
            reason = $lookup.Reason ?? 'Unknown'
        })
        Write-Warning "  $Path : could not tokenise $InputObject - $($lookup.Reason)"
        return $InputObject
    }

    # Prefer an environment alias where one exists, so the definition stays portable.
    $aliasKey = "$type|$($lookup.Name)"
    if ($ReverseAliases.ContainsKey($aliasKey)) {
        return "{{$type`:$($ReverseAliases[$aliasKey])}}"
    }
    return "{{$type`:$($lookup.Name)}}"
}

function ConvertTo-CaaCDefinition {
    <#
    .SYNOPSIS
        Converts one live tenant policy into a repository definition.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [hashtable] $TenantPolicy,
        [Parameter(Mandatory)] [hashtable] $Environment,
        [string] $Owner = 'UNASSIGNED@change.me'
    )

    # aliases are "group:BreakGlass" -> "SG-Real-Name"; invert for import.
    $reverseAliases = @{}
    foreach ($key in $Environment.aliases.Keys) {
        $parts = $key -split ':', 2
        $reverseAliases["$($parts[0])|$($Environment.aliases[$key])"] = $parts[1]
    }

    $unresolved = [System.Collections.Generic.List[object]]::new()
    $body       = Remove-CaaCServerProperty $TenantPolicy
    $state      = if ($body.ContainsKey('state')) { $body['state'] } else { 'disabled' }
    $body.Remove('state')

    Write-Host "Importing '$($TenantPolicy.displayName)' [$state]"
    $tokenised = ConvertTo-CaaCTokenisedBody -InputObject $body -ReverseAliases $reverseAliases -Unresolved $unresolved

    # Reuse an existing CAnnn prefix where the tenant already follows one.
    $policyId = if ($TenantPolicy.displayName -match '^(?<id>[A-Z]{2,4}\d{3})\b') { $Matches['id'] } else { $null }

    $metadata = [ordered]@{
        id           = $policyId
        description  = "Imported from tenant $((Get-MgContext).TenantId). Replace this with the policy's actual intent."
        owner        = $Owner
        targetState  = $state
        adoption     = [ordered]@{
            importedFromTenant = (Get-MgContext).TenantId
            importedFromEnv    = $Environment.name
            importedUtc        = (Get-Date).ToUniversalTime().ToString('o')
            sourcePolicyId     = $TenantPolicy.id
            namingExempt       = $true
        }
    }
    if ($unresolved.Count -gt 0) { $metadata['unresolvedReferences'] = @($unresolved) }

    return [ordered]@{ metadata = $metadata; policy = $tokenised }
}

function Import-CaaCPolicy {
    <#
    .SYNOPSIS
        Imports every Conditional Access policy in the connected tenant as a
        repository definition, ready for review.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [hashtable] $Environment,
        [Parameter(Mandatory)] [string]    $OutputPath,
        [string]   $Owner = 'UNASSIGNED@change.me',
        [string[]] $DisplayNameFilter,
        [string]   $IdPrefix = 'IMP'
    )

    $null     = New-Item -ItemType Directory -Path $OutputPath -Force
    $policies = Get-CaaCGraphCollection $script:PolicyUri

    if ($DisplayNameFilter) {
        $policies = @($policies | Where-Object {
            $name = $_.displayName
            ($DisplayNameFilter | Where-Object { $name -like $_ }).Count -gt 0
        })
    }

    $written = [System.Collections.Generic.List[object]]::new()
    $counter = 0

    foreach ($policy in $policies) {
        $def = ConvertTo-CaaCDefinition -TenantPolicy $policy -Environment $Environment -Owner $Owner

        if (-not $def.metadata.id) {
            $counter++
            $def.metadata.id = '{0}{1:d3}' -f $IdPrefix, $counter
        }

        $slug = ($policy.displayName -replace '[^\w]+', '-').Trim('-')
        if ($slug.Length -gt 70) { $slug = $slug.Substring(0, 70).Trim('-') }
        $file = Join-Path $OutputPath ('{0}-{1}.json' -f $def.metadata.id, $slug)

        $def | ConvertTo-Json -Depth 30 | Set-Content $file -Encoding utf8

        $unresolvedCount = if ($def.metadata.Contains('unresolvedReferences')) { @($def.metadata['unresolvedReferences']).Count } else { 0 }

        $written.Add([pscustomobject]@{
            PolicyId    = $def.metadata.id
            DisplayName = $policy.displayName
            State       = $def.metadata.targetState
            Unresolved  = $unresolvedCount
            File        = Split-Path $file -Leaf
        })
    }

    Write-Host ''
    Write-Host "Imported $($written.Count) policies to $OutputPath"
    $flagged = @($written | Where-Object Unresolved -gt 0)
    if ($flagged) {
        Write-Warning "$($flagged.Count) definitions contain references that could not be tokenised. Review metadata.unresolvedReferences before merging."
    }
    return $written
}

#endregion


Export-ModuleMember -Function @(
    'Connect-CaaC'
    'Invoke-CaaCGraph'
    'Get-CaaCGraphCollection'
    'Get-CaaCDefinition'
    'Get-CaaCEnvironment'
    'Resolve-CaaCToken'
    'Resolve-CaaCLookup'
    'Compare-CaaCPolicy'
    'ConvertTo-CaaCCanonical'
    'Get-CaaCProjection'
    'Export-CaaCTenantState'
    'Invoke-CaaCDeployment'
    'Get-CaaCRingState'
    'Get-CaaCTokenPathMap'
    'Get-CaaCWellKnownValue'
    'Resolve-CaaCReverseLookup'
    'Remove-CaaCServerProperty'
    'ConvertTo-CaaCTokenisedBody'
    'ConvertTo-CaaCDefinition'
    'Import-CaaCPolicy'
)
