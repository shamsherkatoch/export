# Conditional Access as Code

JSON policy definitions reconciled against Microsoft Graph by PowerShell, deployed through Azure DevOps.

Conditional Access is an Entra ID object, not an ARM resource, so Bicep and AVM cannot reach it. This repository manages CA through `/identity/conditionalAccess/policies` on Microsoft Graph.

The toolkit deliberately uses `Invoke-MgGraphRequest` rather than the typed Graph SDK cmdlets. The JSON in `policies/` **is** the Graph request body, so a CA feature that shipped this morning works this afternoon with no module upgrade and no waiting on provider support.

---

## Layout

```
policies/                       one JSON definition per policy
config/environments/            per-tenant object aliases and guardrail settings
src/CaaC.psm1                   auth, token resolution, diff, deployment engine
scripts/Invoke-CaDeploy.ps1     deployment entry point
scripts/Export-CaBackup.ps1     tenant snapshot (rollback artifact)
scripts/Import-CaPolicy.ps1     reverse-engineer live policies into definitions
scripts/Compare-CaImport.ps1    reconcile NonProd against Prod, suggest aliases
tests/PolicyGuardrails.Tests.ps1  offline Pester gates, run on every PR
pipelines/azure-pipelines.yml   validate → plan → report-only → enforce
pipelines/drift-detection.yml   scheduled reverse check
pipelines/import.yml            manual adoption run over both tenants
```

Requires PowerShell 7.2+, the `Microsoft.Graph.Authentication` module, and Pester 5.5+.

---

## Definition format

Each file has a `metadata` block for governance and a `policy` block that is the literal Graph body.

```json
{
  "metadata": {
    "id": "CA001",
    "description": "...",
    "owner": "identity-platform@contoso.com",
    "targetState": "enabled"
  },
  "policy": {
    "displayName": "CA001 - Admins - All apps - Require MFA - v1.0",
    "conditions": { ... },
    "grantControls": { ... }
  }
}
```

Two rules matter here.

**`policy.state` is never authored.** The deployment ring injects it. `ReportOnly` forces `enabledForReportingOnly`; `Enforce` applies `metadata.targetState`. This is what makes it structurally impossible to merge a PR that turns a policy straight on.

**`displayName` is the reconciliation key.** Graph assigns policy IDs at creation, so the toolkit matches repo definitions to tenant policies by name. A rename is therefore a delete-and-recreate. Treat the name as immutable and version it in the name itself (`- v1.0`) rather than renaming.

### Tokens

Object IDs are tenant-specific, so definitions reference directory objects by name and the resolver looks them up at deploy time.

| Token | Resolves to |
|---|---|
| `{{group:Name}}` | group object ID |
| `{{user:upn@domain}}` | user object ID |
| `{{role:Global Administrator}}` | `roleTemplateId` — what `includeRoles` actually expects, not the activated role's object ID |
| `{{app:Display Name}}` | service principal `appId`, which is what `includeApplications` expects |
| `{{servicePrincipal:Name}}` | service principal object ID, for workload identity policies |
| `{{namedLocation:Name}}` | named location ID |
| `{{authStrength:Multifactor authentication}}` | authentication strength policy ID |
| `{{agreement:Name}}` | terms of use agreement ID |
| `{{authContext:Name}}` | authentication context class reference (`c1`, `c2`, ...) |

A token that matches zero or more than one directory object is a hard failure, not a warning.

Where an object is named differently per tenant, add an alias in the environment config rather than forking the definition:

```json
"aliases": {
  "group:BreakGlass": "SG-EntraID-BreakGlass-Accounts"
}
```

The definition still says `{{group:BreakGlass}}` in both tenants.

---

## First use case: CA001, MFA for privileged roles

`policies/CA001-Admins-AllApps-RequireMFA.json` requires MFA for the fourteen standard privileged directory roles across all cloud apps, with break-glass and global exclusion groups excluded.

It's a good first policy because the blast radius is small and well understood, and it exercises the whole toolkit: role tokens, group tokens, authentication strength lookup, the break-glass guardrail, and the report-only ring.

### Getting it live

**1. Prerequisites in the tenant.** Create the break-glass group and the global exclusion group, and put the emergency accounts in the first one. Update `config/environments/prod.json` with the real names and tenant ID.

**2. App registration and service connection.** Grant application permissions `Policy.ReadWrite.ConditionalAccess`, `Policy.Read.All`, `Application.Read.All`, `Group.Read.All`, `RoleManagement.Read.Directory` with admin consent. Create an Azure DevOps service connection named `sc-entra-caac-prod` using **workload identity federation** — no client secrets. Restrict it to the deployment pipelines only.

This app registration can disable every CA policy in your tenant. It is now one of the most privileged principals you own. Scope the ADO environment approvers accordingly, and consider a workload identity CA policy restricting it to your agent egress ranges.

**3. Dry run locally.**

```powershell
./scripts/Invoke-CaDeploy.ps1 -Environment nonprod -Ring Plan -AuthMethod Interactive
```

This resolves every token against the tenant and prints the change set without writing. Token resolution failures surface here, which is where you want them.

**4. Merge.** The PR runs the offline guardrails. `main` then runs Plan (snapshot + diff) and, after environment approval, ReportOnly.

**5. Soak.** Leave it in report-only for at least a week. Check the Conditional Access insights workbook and the report-only results in sign-in logs for admins who would have been blocked — service accounts holding admin roles are the usual surprise.

**6. Enforce.** Re-run the pipeline with `promoteToEnforce = true`. A second environment approval applies `targetState: enabled`.

---

## Adopting existing policies (NonProd and Prod)

Both tenants already have Conditional Access policies. Import brings them under management without rebuilding them by hand, and without touching the tenant.

`scripts/Import-CaPolicy.ps1` is read-only. It reads every live policy, strips server-generated properties (`id`, `createdDateTime`, `templateId`) and null values, lifts `state` into `metadata.targetState`, and reverse-resolves directory object IDs into tokens.

### Reverse resolution is path-driven, and round-tripped

Which properties hold directory references is defined in `Get-CaaCTokenPathMap`, not inferred from "does this string look like a GUID". Several CA properties hold GUIDs that are not directory objects — external tenant IDs under `includeGuestsOrExternalUsers`, for one — and blindly tokenising them would corrupt the policy.

Every reverse lookup is then round-tripped: an ID becomes a token only if resolving that name *forward* returns the same ID. Two groups sharing a display name would otherwise produce a definition that silently targets the wrong object in the next tenant, which is precisely the failure import is supposed to prevent.

Anything that fails to tokenise — a deleted object, a non-unique name — is left as a raw ID and recorded:

```json
"unresolvedReferences": [
  {
    "path": "conditions.users.excludeGroups",
    "type": "group",
    "value": "8f2c...",
    "name": "SG-Legacy-Exclusions",
    "reason": "Name 'SG-Legacy-Exclusions' matched 2 objects."
  }
]
```

The guardrail tests allow a raw GUID **only** if it appears here with a reason. That turns a silently tenant-locked definition into a visible review item.

### Imported definitions keep their existing name

Renaming is a delete-and-recreate, because `displayName` is the reconciliation key. Import therefore preserves the tenant's name and sets `metadata.adoption.namingExempt`, which skips the naming-convention test. Rename deliberately, during a window, when you're ready to accept the recreate — not as a side effect of adoption.

### Reconciling the two tenants

`scripts/Compare-CaImport.ps1` runs offline against the two import directories and sorts matched policies into three buckets:

| Outcome | Meaning | Action |
|---|---|---|
| **Identical** | Tokenised bodies match exactly | One definition serves both tenants |
| **Aliasable** | Differ only in which named object a token points at | Add the suggested aliases, keep one definition |
| **Divergent** | Real structural difference | Converge the tenants, or keep two definitions |

The aliasable case is the interesting one. If Prod excludes `SG-CA-Exclusion-Global-Prod` and NonProd excludes `SG-CA-Exclusion-Global-Test` at the same path, that isn't a policy difference — it's a naming difference. The report emits ready-to-paste alias blocks for both environment configs:

```json
{
  "aliases": {
    "group:SG-CA-Exclusion-Global": "SG-CA-Exclusion-Global-Prod"
  }
}
```

Generated alias keys strip environment markers (`-prod`, `-test`, `-uat`) from the object name. Rename them to something meaningful before committing.

Policies present in only one tenant are listed separately. Usually that's a genuine gap worth closing, or a NonProd experiment that was never promoted.

### The adoption run

```powershell
# 1. Import both tenants (read-only)
./scripts/Import-CaPolicy.ps1 -Environment prod    -OutputPath ./import/prod    -AuthMethod Interactive -Owner identity-platform@contoso.com
./scripts/Import-CaPolicy.ps1 -Environment nonprod -OutputPath ./import/nonprod -AuthMethod Interactive -Owner identity-platform@contoso.com

# 2. Reconcile
./scripts/Compare-CaImport.ps1 -BaselinePath ./import/prod -OverlayPath ./import/nonprod `
                               -ReportPath ./import/reconciliation.md

# 3. Review, add aliases, move reviewed definitions into policies/

# 4. Prove fidelity - this MUST be a complete no-op
./scripts/Invoke-CaDeploy.ps1 -Environment prod -Ring Plan -FailOnChange -AuthMethod Interactive
```

Step 4 is the one that matters. Immediately after import, a Plan against the source tenant must report `NoChange` for every policy. Any drift at that point is an import fidelity bug, not a policy change, and merging it would apply an unintended edit to a live policy on the next run. `-FailOnChange` makes it a build failure rather than something you have to eyeball.

`pipelines/import.yml` does steps 1 and 2 for both tenants on a manual trigger and publishes the drafts plus the reconciliation report as an artifact. It writes nothing to either tenant and commits nothing; a human reviews the artifact and raises the PR.

Import leaves a placeholder description and an `UNASSIGNED@change.me` owner on every draft. The guardrail tests fail on both, so a definition cannot reach `policies/` without someone stating what the policy is for and who owns it.

### The report-only ring, once you own live policies

This is the trap adoption creates. If the report-only ring blindly set `enabledForReportingOnly`, the first routine build after adoption would turn off enforcement on every production policy you just imported.

`Get-CaaCRingState` handles it: the report-only ring never demotes a policy that is already `enabled` in the tenant, and never switches on a policy whose `targetState` is `disabled`. New policies still land in report-only. Use `-ForceReportOnly` when you deliberately want to soak a significant change to a live policy.

---

## Safety model

Four layers, deliberately overlapping.

**Offline guardrails** (`tests/`) run on every PR with no tenant access. They fail the build if a policy targeting admins or all users omits a required break-glass exclusion, if a display name breaks convention, if a raw GUID appears instead of a token, or if a block control is paired with an all-users/all-apps scope.

**Runtime guardrail** (`Assert-CaaCBreakGlass`) repeats the break-glass check *after* token resolution, against real object IDs. The offline test proves the token is there; this proves it resolved to the group the environment actually nominated.

**Ring enforcement.** `Enforce` refuses to create a policy that doesn't already exist in the tenant. Every policy serves time in report-only first. `-AllowCreateInEnforce` exists as an escape hatch and should show up in a change record when used.

**Snapshot before write.** `Export-CaaCTenantState` runs before every deployment and publishes a full tenant export as a pipeline artifact. CA policies have no soft delete and no version history, so this is the only rollback path you have.

The deployment engine **never deletes**. Policies in the tenant that the repo doesn't own are reported as warnings, not removed. Retiring a policy is a deliberate two-step: set `targetState` to `disabled`, enforce, confirm nothing broke, then delete by hand.

---

## Drift detection

`pipelines/drift-detection.yml` runs Plan on a daily schedule and fails if the tenant no longer matches the repo. This is the half of the loop people skip, and it's the half that catches the policy someone edited in the portal during an incident and never folded back.

When it fires, decide whether the portal change was legitimate. If it was, port it into the definition and merge. If it wasn't, re-run the deployment to overwrite. Either way the snapshot artifact tells you exactly what changed.

---

## Adding the next policy

1. Copy `policies/CA001-*.json`, bump the ID, keep the naming convention.
2. `-Ring Plan -AuthMethod Interactive` against the test tenant until it resolves cleanly.
3. PR. Guardrails run.
4. Report-only, soak, enforce.

Where a definition needs a Graph feature the toolkit hasn't seen before, it will usually just work — the body is passed through untouched. Only new *token types* need code changes, and those go in `Resolve-CaaCLookup`.

---

## Known limitations

- **`Get-CaaCProjection` compares only what you declare.** If you remove a property from a definition, the toolkit stops managing it rather than resetting it in the tenant. Explicitly set empty arrays (`"excludeUsers": []`) for anything you want held at empty.
- **Renames are recreates.** By design, since `displayName` is the key.
- **No `What If` integration yet.** The Graph CA What If API is the natural next addition to the Plan stage — evaluating a named test user against the proposed policy set before anything is written.
- **Authentication context and terms of use** are supported as token types but not demonstrated in CA001.

- **Import fidelity is only proven by the no-op Plan.** Run `-Ring Plan -FailOnChange` after every import batch. It is the only thing standing between a subtle tokenisation bug and an unintended edit to a live policy.
- **Cross-tenant matching is by display name.** If NonProd and Prod named the same policy differently, `Compare-CaImport.ps1` will report both as single-tenant. Align the names, or match them by hand.
- **`sessionControls` and device filters are passed through untouched.** They contain no directory references, so import is lossless there, but the comparison also can't tell you anything useful about them beyond equal/not equal.
