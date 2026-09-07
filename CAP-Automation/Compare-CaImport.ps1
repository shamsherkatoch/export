<#
.SYNOPSIS
    Reconciles two sets of imported definitions (typically NonProd and Prod) and
    reports what can share a single definition and what genuinely diverges.

.DESCRIPTION
    Runs entirely offline against the output of Import-CaPolicy.ps1. No Graph access.

    Policies are matched by display name. For each matched pair the tokenised policy
    bodies are compared. Three outcomes:

      Identical  - one definition serves both tenants. Promote it as-is.
      Aliasable  - the bodies differ only in which named object a token points at.
                   Suggested alias entries are emitted for the environment configs.
      Divergent  - real structural difference. Needs a human decision: converge the
                   tenants, or keep separate definitions.

.EXAMPLE
    ./scripts/Compare-CaImport.ps1 -BaselinePath ./import/prod -OverlayPath ./import/nonprod `
                                   -BaselineEnv prod -OverlayEnv nonprod -ReportPath ./import/reconciliation.md
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $BaselinePath,
    [Parameter(Mandatory)] [string] $OverlayPath,
    [string] $BaselineEnv = 'prod',
    [string] $OverlayEnv  = 'nonprod',
    [string] $ReportPath,
    [string] $SummaryPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $repoRoot 'src/CaaC.psm1') -Force

function Get-Definitions {
    param([string] $Path)
    $map = @{}
    foreach ($file in (Get-ChildItem $Path -Filter '*.json' -File)) {
        $def = Get-Content $file.FullName -Raw | ConvertFrom-Json -AsHashtable -Depth 30
        $map[$def.policy.displayName] = $def
    }
    return $map
}

function Get-LeafDiff {
    <#
        Walks two policy bodies together and returns per-path differences.
        Arrays are compared as sets, since CA reference lists are unordered.
    #>
    param($A, $B, [string] $Path = '', [System.Collections.Generic.List[object]] $Acc)

    if ($A -is [System.Collections.IDictionary] -or $B -is [System.Collections.IDictionary]) {
        $keys = @()
        if ($A -is [System.Collections.IDictionary]) { $keys += $A.Keys }
        if ($B -is [System.Collections.IDictionary]) { $keys += $B.Keys }
        foreach ($key in ($keys | Sort-Object -Unique)) {
            $childPath = if ($Path) { "$Path.$key" } else { $key }
            $av = if ($A -is [System.Collections.IDictionary] -and $A.Contains($key)) { $A[$key] } else { $null }
            $bv = if ($B -is [System.Collections.IDictionary] -and $B.Contains($key)) { $B[$key] } else { $null }
            Get-LeafDiff -A $av -B $bv -Path $childPath -Acc $Acc
        }
        return
    }

    $aIsArray = ($A -isnot [string] -and $A -is [System.Collections.IEnumerable])
    $bIsArray = ($B -isnot [string] -and $B -is [System.Collections.IEnumerable])

    if ($aIsArray -or $bIsArray) {
        $aSet = @($A) | Where-Object { $null -ne $_ } | ForEach-Object { ConvertTo-CaaCCanonical $_ }
        $bSet = @($B) | Where-Object { $null -ne $_ } | ForEach-Object { ConvertTo-CaaCCanonical $_ }
        $onlyA = @($aSet | Where-Object { $_ -notin $bSet })
        $onlyB = @($bSet | Where-Object { $_ -notin $aSet })
        if ($onlyA.Count -or $onlyB.Count) {
            $Acc.Add([ordered]@{ path = $Path; onlyBaseline = $onlyA; onlyOverlay = $onlyB })
        }
        return
    }

    if ((ConvertTo-CaaCCanonical $A) -ne (ConvertTo-CaaCCanonical $B)) {
        $Acc.Add([ordered]@{ path = $Path; onlyBaseline = @("$A"); onlyOverlay = @("$B") })
    }
}

function New-AliasKey {
    # Strip common environment markers so the alias name is environment-neutral.
    param([string] $Type, [string] $TokenValue, [string] $PolicyId, [string] $Path)

    $name = $TokenValue -replace '(?i)[-_ ](prod|prd|production|nonprod|npd|test|tst|dev|uat|stg|staging)\b', ''
    $name = ($name -replace '[^A-Za-z0-9]+', '-').Trim('-')
    if (-not $name) { $name = "$PolicyId-$($Path.Split('.')[-1])" }
    return "$Type`:$name"
}

$baseline = Get-Definitions $BaselinePath
$overlay  = Get-Definitions $OverlayPath

$identical      = [System.Collections.Generic.List[object]]::new()
$aliasable      = [System.Collections.Generic.List[object]]::new()
$divergent      = [System.Collections.Generic.List[object]]::new()
$aliasSuggestions = [ordered]@{ $BaselineEnv = [ordered]@{}; $OverlayEnv = [ordered]@{} }

foreach ($name in ($baseline.Keys | Sort-Object)) {
    if (-not $overlay.ContainsKey($name)) { continue }

    $a = $baseline[$name]; $b = $overlay[$name]
    if ((ConvertTo-CaaCCanonical $a.policy) -eq (ConvertTo-CaaCCanonical $b.policy)) {
        $identical.Add([pscustomobject]@{ PolicyId = $a.metadata.id; DisplayName = $name })
        continue
    }

    $diffs = [System.Collections.Generic.List[object]]::new()
    Get-LeafDiff -A $a.policy -B $b.policy -Acc $diffs

    # A difference is aliasable if, at every differing path, both sides hold exactly
    # one token of the same type. That is a naming difference, not a policy difference.
    $canAlias = $true
    $pending  = [System.Collections.Generic.List[object]]::new()

    foreach ($diff in $diffs) {
        $aTok = @($diff.onlyBaseline | ForEach-Object { $_.Trim('"') } | Where-Object { $_ -match '^\{\{(?<t>[A-Za-z]+):(?<v>.+)\}\}$' })
        $bTok = @($diff.onlyOverlay  | ForEach-Object { $_.Trim('"') } | Where-Object { $_ -match '^\{\{(?<t>[A-Za-z]+):(?<v>.+)\}\}$' })

        if ($aTok.Count -ne 1 -or $bTok.Count -ne 1 -or
            $aTok.Count -ne @($diff.onlyBaseline).Count -or $bTok.Count -ne @($diff.onlyOverlay).Count) {
            $canAlias = $false
            continue
        }

        $aTok[0] -match '^\{\{(?<t>[A-Za-z]+):(?<v>.+)\}\}$' | Out-Null
        $aType = $Matches['t']; $aVal = $Matches['v']
        $bTok[0] -match '^\{\{(?<t>[A-Za-z]+):(?<v>.+)\}\}$' | Out-Null
        $bType = $Matches['t']; $bVal = $Matches['v']

        if ($aType -ne $bType) { $canAlias = $false; continue }

        $key = New-AliasKey -Type $aType -TokenValue $aVal -PolicyId $a.metadata.id -Path $diff.path
        $pending.Add([pscustomobject]@{ Path = $diff.path; AliasKey = $key; Baseline = $aVal; Overlay = $bVal })
    }

    if ($canAlias -and $pending.Count -gt 0) {
        foreach ($item in $pending) {
            $aliasSuggestions[$BaselineEnv][$item.AliasKey] = $item.Baseline
            $aliasSuggestions[$OverlayEnv][$item.AliasKey]  = $item.Overlay
        }
        $aliasable.Add([pscustomobject]@{ PolicyId = $a.metadata.id; DisplayName = $name; Mappings = $pending })
    }
    else {
        $divergent.Add([pscustomobject]@{ PolicyId = $a.metadata.id; DisplayName = $name; Differences = $diffs })
    }
}

$baselineOnly = @($baseline.Keys | Where-Object { -not $overlay.ContainsKey($_) } | Sort-Object)
$overlayOnly  = @($overlay.Keys  | Where-Object { -not $baseline.ContainsKey($_) } | Sort-Object)

# ---- Report -----------------------------------------------------------------

$md = [System.Text.StringBuilder]::new()
$null = $md.AppendLine("# Conditional Access reconciliation: $BaselineEnv vs $OverlayEnv")
$null = $md.AppendLine()
$null = $md.AppendLine("Generated $((Get-Date).ToUniversalTime().ToString('u'))")
$null = $md.AppendLine()
$null = $md.AppendLine("| Outcome | Count |")
$null = $md.AppendLine("|---|---|")
$null = $md.AppendLine("| Identical (promote as one definition) | $($identical.Count) |")
$null = $md.AppendLine("| Aliasable (same policy, different object names) | $($aliasable.Count) |")
$null = $md.AppendLine("| Divergent (needs a decision) | $($divergent.Count) |")
$null = $md.AppendLine("| Only in $BaselineEnv | $($baselineOnly.Count) |")
$null = $md.AppendLine("| Only in $OverlayEnv | $($overlayOnly.Count) |")
$null = $md.AppendLine()

if ($identical.Count) {
    $null = $md.AppendLine("## Identical`n")
    foreach ($item in $identical) { $null = $md.AppendLine("- ``$($item.PolicyId)`` $($item.DisplayName)") }
    $null = $md.AppendLine()
}

if ($aliasable.Count) {
    $null = $md.AppendLine("## Aliasable`n")
    $null = $md.AppendLine("These differ only in which named object a token points at. Add the suggested aliases to both environment configs and keep one definition.`n")
    foreach ($item in $aliasable) {
        $null = $md.AppendLine("### ``$($item.PolicyId)`` $($item.DisplayName)`n")
        $null = $md.AppendLine("| Path | Alias key | $BaselineEnv | $OverlayEnv |")
        $null = $md.AppendLine("|---|---|---|---|")
        foreach ($m in $item.Mappings) {
            $null = $md.AppendLine("| ``$($m.Path)`` | ``$($m.AliasKey)`` | $($m.Baseline) | $($m.Overlay) |")
        }
        $null = $md.AppendLine()
    }
}

if ($divergent.Count) {
    $null = $md.AppendLine("## Divergent`n")
    $null = $md.AppendLine("Real differences in policy behaviour. Either converge the tenants, or keep two definitions and scope them per environment.`n")
    foreach ($item in $divergent) {
        $null = $md.AppendLine("### ``$($item.PolicyId)`` $($item.DisplayName)`n")
        $null = $md.AppendLine("| Path | Only in $BaselineEnv | Only in $OverlayEnv |")
        $null = $md.AppendLine("|---|---|---|")
        foreach ($d in $item.Differences) {
            $null = $md.AppendLine("| ``$($d.path)`` | $((@($d.onlyBaseline) -join '<br>')) | $((@($d.onlyOverlay) -join '<br>')) |")
        }
        $null = $md.AppendLine()
    }
}

foreach ($pair in @(@{ Label = $BaselineEnv; Items = $baselineOnly }, @{ Label = $OverlayEnv; Items = $overlayOnly })) {
    if ($pair.Items.Count) {
        $null = $md.AppendLine("## Only in $($pair.Label)`n")
        foreach ($name in $pair.Items) { $null = $md.AppendLine("- $name") }
        $null = $md.AppendLine()
    }
}

if ($aliasSuggestions[$BaselineEnv].Count) {
    $null = $md.AppendLine("## Suggested alias blocks`n")
    foreach ($envName in @($BaselineEnv, $OverlayEnv)) {
        $null = $md.AppendLine("``config/environments/$envName.json``:`n")
        $null = $md.AppendLine('```json')
        $null = $md.AppendLine((@{ aliases = $aliasSuggestions[$envName] } | ConvertTo-Json -Depth 5))
        $null = $md.AppendLine('```')
        $null = $md.AppendLine()
    }
    $null = $md.AppendLine("Alias key names are generated from the object name with environment markers stripped. Rename them to something meaningful before committing.")
}

$report = $md.ToString()
if ($ReportPath) {
    $null = New-Item -ItemType Directory -Path (Split-Path $ReportPath -Parent) -Force -ErrorAction SilentlyContinue
    $report | Set-Content $ReportPath -Encoding utf8
    Write-Host "Reconciliation report written to $ReportPath"
}
else {
    Write-Host $report
}

$summary = [ordered]@{
    baselineEnv      = $BaselineEnv
    overlayEnv       = $OverlayEnv
    identical        = @($identical.DisplayName)
    aliasable        = @($aliasable | ForEach-Object { $_.DisplayName })
    divergent        = @($divergent | ForEach-Object { $_.DisplayName })
    onlyInBaseline   = $baselineOnly
    onlyInOverlay    = $overlayOnly
    aliasSuggestions = $aliasSuggestions
}
if ($SummaryPath) { $summary | ConvertTo-Json -Depth 10 | Set-Content $SummaryPath -Encoding utf8 }

Write-Host ''
Write-Host "identical=$($identical.Count) aliasable=$($aliasable.Count) divergent=$($divergent.Count) baselineOnly=$($baselineOnly.Count) overlayOnly=$($overlayOnly.Count)"
