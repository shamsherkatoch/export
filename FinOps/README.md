# FinOps — Azure RG Tag Reconciliation

Reconcile Azure resource-group tags against a SharePoint-hosted CSV that is the source of truth for four FinOps tag values. An Azure DevOps pipeline runs a PowerShell task on a Microsoft-hosted agent, authenticates as a User-Assigned Managed Identity (UAMI) via a federated service connection, reads the CSV through Microsoft Graph, and merges tag values onto every matching resource group under a target management group.

For the authoritative spec (managed keys, normalization rules, preservation rules, and change log), see [`claude.md`](./claude.md). **Every material change to this solution must be recorded in the Change log in `claude.md`** — this README describes how to run and operate it; the spec lives there.

## What it does

- Pulls a CSV from SharePoint via Microsoft Graph.
- Builds an index keyed by `(SubscriptionId, ResourceGroupName)` (both lower-cased).
- Enumerates every subscription under the configured management group.
- For each resource group that appears in the CSV, compares the four managed tag values (`BusinessUnit`, `CostObject`, `GeneralLedgerCode`, `FinancialDelegate`) after normalization (strip all whitespace, uppercase invariant).
- Merges only the changed managed keys onto the RG — other tags are left untouched.
- Re-reads the RG after writing and asserts the values took.
- Prints a summary: `inspected / matched / updated / unchanged`.

Resource groups whose `(subscription, RG)` pair is not in the CSV are skipped entirely.

## Repository layout

```
FinOps/
├── claude.md                              # Spec + change log (authoritative)
├── README.md                              # This file — overview and operating notes
├── pipelines/
│   └── azure-pipelines.yml                # ADO pipeline (schedule + task)
└── scripts/
    └── Invoke-TagReconciliation.ps1       # PowerShell 7 reconciliation script
```

## Runtime

- **Where**: Azure DevOps, Microsoft-hosted `windows-latest` agent.
- **When**: scheduled daily at 06:00 UTC (`schedules` block in the pipeline).
- **Task**: `AzurePowerShell@5` with `pwsh: true`, `azurePowerShellVersion: LatestVersion`.
- **Auth**: workload-identity federated service connection backed by the UAMI. No secrets in variables or scripts.
- **Default mode**: dry run (`whatIf: true`). Scheduled runs report intended changes without writing.

## Prerequisites

### 1. Variable group `finops-tag-reconciliation`

Create it in the pipeline's project under **Pipelines → Library** with these variables (none are secrets):

| Variable | Example | Purpose |
| --- | --- | --- |
| `serviceConnectionName` | `finops-uami-federated` | ADO service connection (federated) backed by the UAMI. |
| `sharePointHostname` | `contoso.sharepoint.com` | Host of the SharePoint tenant. |
| `sharePointSitePath` | `/sites/finops` | Server-relative site path. |
| `csvItemPath` | `Shared Documents/finops/tags.csv` | Drive-root-relative path to the CSV. |
| `managementGroupId` | `mg-contoso-root` | Management group **name** (not display name). |

Link this variable group to the pipeline (already referenced via `- group: finops-tag-reconciliation`).

### 2. UAMI and federated service connection

- Create a User-Assigned Managed Identity in a suitable subscription.
- In Azure DevOps, create a **workload identity federation (automatic or manual)** service connection that federates back to that UAMI. Name it to match `serviceConnectionName` above.

### 3. UAMI access

The service connection is backed by the UAMI, so every RBAC/Graph grant below is assigned to the UAMI's object (as principalId in `New-AzRoleAssignment`, or as the app in Graph). Assign at the **management group** scope so it inherits down to every subscription/RG the pipeline touches — do not assign per subscription.

#### 3a. Azure Resource Manager (management group + everything under it)

Assign these built-in roles to the UAMI at scope `/providers/Microsoft.Management/managementGroups/{managementGroupId}`:

| Role | Why this script needs it | Key actions it grants |
| --- | --- | --- |
| **Reader** | Enumerate the MG's subscription tree, load RGs and their current tags. | `Microsoft.Management/managementGroups/read`, `Microsoft.Management/managementGroups/descendants/read`, `Microsoft.Resources/subscriptions/read`, `Microsoft.Resources/subscriptions/resourceGroups/read` (Reader is `*/read`, so all of these are covered). |
| **Tag Contributor** | Merge managed tag keys onto matching RGs and re-read to verify. | `Microsoft.Resources/tags/*` (read + write + delete on tags), plus `Microsoft.Resources/subscriptions/resourceGroups/read` so it can target the RG. |

Concrete actions the script exercises (all covered by the two roles above):

- `Microsoft.Management/managementGroups/read` — resolve the MG.
- `Microsoft.Management/managementGroups/descendants/read` — `GET .../managementGroups/{id}/descendants` to list subscriptions.
- `Microsoft.Resources/subscriptions/read` — `Set-AzContext -SubscriptionId ...`.
- `Microsoft.Resources/subscriptions/resourceGroups/read` — `Get-AzResourceGroup` + post-write re-read.
- `Microsoft.Resources/tags/read` — read existing tag hashtable before diffing.
- `Microsoft.Resources/tags/write` — `Update-AzTag -Operation Merge`.

Do **not** grant `Contributor` or `Owner` — Tag Contributor is the least-privileged write role that satisfies this workload. Do **not** grant `Microsoft.Authorization/*/write` — the pipeline never edits role assignments. If you build a custom role instead of using Tag Contributor, its `actions` must include everything in the bullet list above and the `notActions` must not exclude `Microsoft.Resources/tags/write`.

Reference PowerShell to grant them (run once, per MG):

```powershell
$mgScope   = "/providers/Microsoft.Management/managementGroups/<managementGroupId>"
$uamiObjId = "<UAMI principalId (objectId of the managed identity)>"

New-AzRoleAssignment -ObjectId $uamiObjId -RoleDefinitionName "Reader"          -Scope $mgScope
New-AzRoleAssignment -ObjectId $uamiObjId -RoleDefinitionName "Tag Contributor" -Scope $mgScope
```

#### 3b. Microsoft Graph → SharePoint (CSV read)

- Grant the UAMI's app the **`Sites.Selected`** application permission on Microsoft Graph and admin-consent it.
- Grant the app `read` on the specific site (not the whole tenant) via Graph:

  ```
  POST https://graph.microsoft.com/v1.0/sites/{siteId}/permissions
  {
    "roles": ["read"],
    "grantedToIdentities": [
      { "application": { "id": "<UAMI clientId>", "displayName": "<UAMI name>" } }
    ]
  }
  ```

- `read` is sufficient — the script only downloads the file, it never writes back.

#### 3c. Azure DevOps

The workload-identity service connection (`serviceConnectionName`) must be **authorized for the pipeline** (either at project level or via a pipeline-scoped grant). No further ADO role beyond that is required on the UAMI.

### 4. CSV shape

CSV in SharePoint must have (at minimum) these headers:

```
SubscriptionId,ResourceGroupName,BusinessUnit,CostObject,GeneralLedgerCode,FinancialDelegate
```

Rows with an empty `SubscriptionId` or `ResourceGroupName` are skipped. Missing required columns cause `New-CsvIndex` to throw and fail the run.

## Running the pipeline

### Scheduled (default)

The `schedules:` block queues the pipeline daily at 06:00 UTC against `main`. It runs with `whatIf = true`, so nothing is written — the run logs what would change. Use these runs as a drift report.

### Ad-hoc dry run

Queue the pipeline manually from ADO. Leave the `whatIf` parameter checked. Same behavior as the scheduled run.

### Real write

Queue the pipeline manually and **uncheck `whatIf`** (or set it to `false`). The task then calls `Update-AzTag ... -Operation Merge` and verifies each written value.

## Operating notes

### Reading a run

- **Preamble**: source URL of the CSV, row count, unique RG-tuple count, subscription count.
- **Per subscription**: `=== Subscription: <guid> ===`, then per RG that matched a CSV row: one line per managed key, either `match ('X')` or `'old' -> 'new'`. RGs with no diffs log `no changes`.
- **Write mode**: `merged N key(s) OK` after each successful write. If verify fails, the run throws immediately.
- **Dry-run mode**: `WhatIf: would merge N key(s)` instead of a write.
- **Summary line** at the end: `Summary: inspected=X, matched=Y, updated=Z, unchanged=W`. `updated + unchanged = matched`. `matched ≤ inspected`.

### Turning drift into a real update

1. Run the pipeline in dry-run mode and inspect the log to confirm the planned changes are what you expect.
2. If OK, queue a run with `whatIf = false`. Consider scoping the CSV first if the change set is large — the script has no built-in filter, so the CSV itself is the scope control.
3. After the write run, spot-check a few RGs in the portal, or diff the run's summary against the previous day's dry-run summary.

### Common failure modes

- **`Set-AzContext failed` on a subscription** — the UAMI likely lacks Reader on that subscription, or the subscription is disabled. Fix the role assignment; the script continues past the subscription and prints a warning.
- **`CSV is missing required column`** — a header was renamed or removed. Fix the CSV; do not edit the script to accept the new name without also updating the [Managed tag keys](./claude.md#managed-tag-keys) section and adding a Change log entry in `claude.md`.
- **`Verify failed for <RG>`** — the RG was written but the re-read did not observe the expected value. Usually caused by a concurrent tag write from another process. Re-run; if it persists, investigate the other writer.
- **401/403 from Graph on the site fetch** — the UAMI is missing `Sites.Selected` consent or does not have `read` on the specific site. Re-grant via `POST /sites/{siteId}/permissions`.
- **Duplicate `(SubscriptionId, ResourceGroupName)` rows in CSV** — the last row wins (later rows overwrite earlier ones in `$index`). Deduplicate at the source.

### Making changes safely

- Keep the managed-keys list in `$script:ManagedKeys` in `Invoke-TagReconciliation.ps1` and mirror any change in `claude.md`.
- Never switch `Update-AzTag` to `-Operation Replace` — that would clobber unmanaged tags.
- Do not add secrets to the variable group. Auth stays on the federated UAMI.
- After a change, run the pipeline once in dry-run mode before promoting it to a write run.
- Log the change as a dated entry in the [Change log in `claude.md`](./claude.md#change-log) before merging.

## Support

Owner: FinOps team. For questions about the spec or history, start with `claude.md`. For questions about a specific run, start with the ADO run log — the per-RG output is designed to be greppable by RG name.
