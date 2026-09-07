#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

<#
    Offline guardrails. No Graph connection, no tenant access, no secrets.
    These run on every pull request and are the gate that stops a merge from
    locking every administrator out of the tenant.

    Imported definitions get two narrow exemptions, both explicit in metadata:
      - metadata.adoption.namingExempt  : keeps the tenant's existing display name,
                                          because renaming is a delete-and-recreate.
      - metadata.unresolvedReferences   : allows a raw object ID that could not be
                                          safely tokenised, provided it is declared.
    Nothing exempts a definition from the lockout checks.
#>

BeforeDiscovery {
    $script:RepoRoot = Split-Path $PSScriptRoot -Parent
    $script:EnvName  = if ($env:CAAC_ENVIRONMENT) { $env:CAAC_ENVIRONMENT } else { 'prod' }

    $script:EnvConfig = Get-Content (Join-Path $RepoRoot "config/environments/$EnvName.json") -Raw |
        ConvertFrom-Json -AsHashtable -Depth 20

    $script:Definitions = Get-ChildItem (Join-Path $RepoRoot 'policies') -Filter '*.json' -File | ForEach-Object {
        @{
            FileName = $_.Name
            Raw      = (Get-Content $_.FullName -Raw)
            Def      = (Get-Content $_.FullName -Raw | ConvertFrom-Json -AsHashtable -Depth 30)
        }
    }
}

Describe 'Repository shape' {

    It 'contains at least one policy definition' {
        @($Definitions).Count | Should -BeGreaterThan 0
    }

    It 'has no duplicate policy IDs' {
        $ids = $Definitions.Def.metadata.id
        ($ids | Group-Object | Where-Object Count -gt 1).Count | Should -Be 0
    }

    It 'has no duplicate display names' {
        $names = $Definitions.Def.policy.displayName
        ($names | Group-Object | Where-Object Count -gt 1).Count | Should -Be 0
    }
}

Describe 'Definition <_.FileName>' -ForEach $Definitions {

    Context 'Metadata' {

        It 'declares id, description, owner and targetState' {
            foreach ($key in 'id', 'description', 'owner', 'targetState') {
                $Def.metadata.Keys | Should -Contain $key
            }
        }

        It 'has a valid targetState' {
            $Def.metadata.targetState | Should -BeIn @('enabled', 'disabled', 'enabledForReportingOnly')
        }

        It 'has an owner that looks like a contactable mailbox' {
            $Def.metadata.owner | Should -Match '^[^@\s]+@[^@\s]+\.[^@\s]+$'
        }
    }

    Context 'Import review' {

        It 'has no unassigned owner left over from import' {
            $Def.metadata.owner | Should -Not -Match '(?i)UNASSIGNED|change\.me'
        }

        It 'has a real description, not the import placeholder' {
            $Def.metadata.description | Should -Not -Match '(?i)Replace this with the policy'
        }

        It 'declares a reason for every raw object ID it still carries' {
            # Imported policies may legitimately keep an untokenised ID (deleted object,
            # or a display name that is not unique). It must be declared, with a reason,
            # so it shows up in review rather than hiding in an array of GUIDs.
            $declared = @($Def.metadata.unresolvedReferences) | ForEach-Object { $_.value }
            $users    = $Def.policy.conditions.users
            $values   = @($users.includeUsers) + @($users.excludeUsers) +
                        @($users.includeGroups) + @($users.excludeGroups) +
                        @($users.includeRoles) + @($users.excludeRoles)

            foreach ($value in ($values | Where-Object { $_ })) {
                if ($value -match '^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$') {
                    $value | Should -BeIn $declared -Because 'raw GUIDs are tenant-specific and must be declared in metadata.unresolvedReferences'
                }
            }
        }

        It 'gives a reason for each unresolved reference' {
            foreach ($ref in @($Def.metadata.unresolvedReferences)) {
                $ref.reason | Should -Not -BeNullOrEmpty
                $ref.path   | Should -Not -BeNullOrEmpty
            }
        }
    }

    Context 'Policy body' {

        It 'does not hardcode state (the ring injects it)' {
            $Def.policy.Keys | Should -Not -Contain 'state'
        }

        It 'follows the display name convention' {
            $exempt = $Def.metadata.ContainsKey('adoption') -and $Def.metadata.adoption.namingExempt
            if ($exempt) {
                Set-ItResult -Skipped -Because 'the policy was imported and keeps its existing tenant name; renaming is a delete-and-recreate'
                return
            }
            $Def.policy.displayName | Should -Match $EnvConfig.guardrails.namingPattern
        }

        It 'declares at least one grant or session control' {
            ($Def.policy.ContainsKey('grantControls') -or $Def.policy.ContainsKey('sessionControls')) |
                Should -BeTrue
        }

        It 'uses only supported token types' {
            $supported = 'group', 'user', 'role', 'app', 'servicePrincipal', 'namedLocation',
                         'authStrength', 'agreement', 'authContext'
            foreach ($match in [regex]::Matches($Raw, '\{\{(?<type>[A-Za-z]+):')) {
                $match.Groups['type'].Value | Should -BeIn $supported
            }
        }
    }

    Context 'Lockout protection' {

        It 'excludes every required break-glass group when the policy targets admins or everyone' {
            $users = $Def.policy.conditions.users

            $targetsEveryone = ('All' -in @($users.includeUsers)) -or
                               (@($users.includeRoles).Count  -gt 0) -or
                               (@($users.includeGroups).Count -gt 0)

            if (-not $targetsEveryone) {
                Set-ItResult -Skipped -Because 'the policy targets a narrow, explicit user set'
                return
            }

            $excluded = @($users.excludeGroups) + @($users.excludeUsers)
            foreach ($required in @($EnvConfig.guardrails.requiredExclusionGroups)) {
                $excluded | Should -Contain "{{$required}}" -Because "$($Def.metadata.id) must never apply to break-glass accounts"
            }
        }

        It 'does not combine a block control with an all-users, all-apps scope' {
            $grant = $Def.policy.grantControls
            if (-not $grant -or 'block' -notin @($grant.builtInControls)) {
                Set-ItResult -Skipped -Because 'the policy is not a block policy'
                return
            }

            $allUsers = 'All' -in @($Def.policy.conditions.users.includeUsers)
            $allApps  = 'All' -in @($Def.policy.conditions.applications.includeApplications)
            ($allUsers -and $allApps) | Should -BeFalse -Because 'a global block policy is a tenant-wide outage'
        }
    }
}
