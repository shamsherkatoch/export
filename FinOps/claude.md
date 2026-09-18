# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository. It is also the single source of truth for change history: any future change to the solution must be recorded in the [Change log](#change-log) at the bottom of this file.

## Purpose

Reconcile Azure resource-group tags against a SharePoint-hosted CSV that is treated as the source of truth. An Azure DevOps pipeline runs a PowerShell task on a Microsoft-hosted agent, using a User-Assigned Managed Identity (UAMI) with a federated service connection, to read the CSV via Microsoft Graph and update tag values on every resource group across every subscription under a target management group.

## Repository layout

- `pipelines/azure-pipelines.yml` — Azure DevOps pipeline definition. Scheduled daily at 06:00 UTC, runs on `windows-latest`, invokes the PowerShell script via `AzurePowerShell@5` with the federated service connection. Exposes a `whatIf` boolean parameter (defaults to `true`) so ad-hoc runs are dry-run by default.
- `scripts/Invoke-TagReconciliation.ps1` — PowerShell 7 script that performs the reconciliation. Requires `Az.Accounts` and `Az.Resources`.
- `claude.md` — this file. Spec and change history.

## Managed tag keys

Only these four keys are reconciled from the CSV. Tag keys are stable across the tenant; only values change per row.

- `BusinessUnit`
- `CostObject`
- `GeneralLedgerCode`
- `FinancialDelegate`

The list lives in the script as `$script:ManagedKeys` — that array is the authoritative reference at runtime.

## CSV contract

The CSV loaded from SharePoint must have a header row with, at minimum, these columns:

- `SubscriptionName` — subscription **display name** (case-insensitive, trimmed, lower-cased when building the lookup key). This is the sole match key. The script does not read subscription IDs from the CSV and does not require an RG-name column.
- `BusinessUnit`, `CostObject`, `GeneralLedgerCode`, `FinancialDelegate` — the four managed tag values applied to every RG under the matched subscription.

`New-CsvIndex` throws if any required column is missing. Rows with an empty `SubscriptionName` are skipped. Extra columns (e.g. `SubscriptionId` kept for humans, `Owner`, `Comments`) are allowed but not read. The lookup key is `"<subscriptionName lower>"`.

Duplicate `SubscriptionName` rows silently let the later row win (last-write wins in `$index`). Deduplicate at the source.

## Value normalization

CSV values are never written verbatim. `ConvertTo-NormalizedTagValue` performs:

1. Strip **all** whitespace (regex `\s+` replaced with empty), not only trim.
2. Uppercase using invariant culture.
3. Return `$null` for null/whitespace-only input; keys with a `$null` normalized value are dropped from the desired set for that row.

Compare-and-update runs against the normalized value — a resource group whose current tag already equals the normalized value is a no-op (logged as `match`).

## Runtime shape

- **Trigger**: Azure DevOps pipeline, Microsoft-hosted `windows-latest` agent, `AzurePowerShell@5` task with `pwsh: true` and `azurePowerShellVersion: LatestVersion`.
- **Auth**: UAMI + workload-identity federated service connection (variable `serviceConnectionName`). No secrets in pipeline variables or scripts.
- **CSV fetch**: Microsoft Graph. Token is acquired via `Get-AzAccessToken -ResourceUrl 'https://graph.microsoft.com'` and unwrapped from `SecureString` when needed. The site is resolved with `GET /v1.0/sites/{hostname}:{sitePath}`, then the file is fetched with `GET /v1.0/sites/{siteId}/drive/root:/{urlEscapedItemPath}:/content`.
- **Scope enumeration**: `GET https://management.azure.com/providers/Microsoft.Management/managementGroups/{id}/descendants?api-version=2020-05-01`, paginated via `nextLink`. Only nodes of type `Microsoft.Management/managementGroups/subscriptions` are collected; both `name` (subscription GUID) and `properties.displayName` (subscription display name) are captured for each.
- **Per subscription**: match `properties.displayName` (case-insensitive, trimmed) against the CSV's `SubscriptionName` index. Subscriptions not in the CSV are skipped with a `skipped — SubscriptionName ... not in CSV` log line. For matched subscriptions, `Set-AzContext -SubscriptionId $sub.Id`, then `Get-AzResourceGroup` to list every RG. If `Set-AzContext` fails, the subscription is skipped with a warning.
- **Per resource group**: every RG in a matched subscription receives the CSV row's tag values. Compute the diff between current tags and the desired normalized values, log every key (`match` vs `'old' -> 'new'`), and either write or log a WhatIf line. Only keys whose current value differs from the CSV value are written.
- **Write**: `Update-AzTag -ResourceId $rg.ResourceId -Tag $toUpdate -Operation Merge`. Merge is required — never `-Operation Replace`.
- **Verify**: after write, re-fetch the RG with `Get-AzResourceGroup` and assert each written key equals the expected normalized value. Mismatch throws.
- **Summary**: script prints subscription counts (`subs inspected / matched / skipped`) and RG counts (`rgs inspected / updated / unchanged`) at the end.

## Pipeline parameters and variables

Parameters (set at queue time):

- `whatIf` (bool, default `true`) — passed to the script as `-WhatIfMode`. Scheduled runs use the default, so the schedule is dry-run unless the pipeline default is flipped. To perform writes, queue the pipeline manually with `whatIf = false`.

Pipeline variables defined directly on the pipeline (**Pipeline → Edit → Variables** in the ADO UI). Not a variable group and not a YAML `variables:` block. All non-secret, all required:

- `serviceConnectionName` — ADO service connection backed by the UAMI (federated).
- `sharePointHostname` — e.g. `contoso.sharepoint.com`.
- `sharePointSitePath` — server-relative path, e.g. `/sites/finops`.
- `csvItemPath` — drive-root-relative, e.g. `Shared Documents/finops/tags.csv`.
- `managementGroupId` — management group **name** (not display name).

## Access the UAMI must hold

- Microsoft Graph permission to read the SharePoint file. `Sites.Selected` scoped to the specific site is the intended grant; the app registration/UAMI must be granted access to the site via `POST /sites/{siteId}/permissions` with role `read` (or `write` if that ever becomes necessary — it does not for this workload).
- Reader at the target management group — to list subscriptions (`descendants` API) and read RG tags (`Get-AzResourceGroup`).
- Tag Contributor (or equivalent) at the management group — to write tag values on any RG under it without broader control. `Update-AzTag` with `Operation=Merge` is what the role needs to allow.

## Preservation rules

- Any tag write must **merge**, never replace: only the four managed keys may be touched. Tags outside those keys must remain on the resource group. A write that sends the full tag hashtable without preserving existing keys is a bug.
- Subscriptions whose `SubscriptionName` is not present in the CSV must not be entered at all — the script `continue`s past them before calling `Set-AzContext` or `Get-AzResourceGroup`.
- Only tag keys whose current RG value differs from the CSV value are written; matching keys are logged as `match` and not sent to `Update-AzTag`.
- Log per resource group: keys inspected, current value vs. normalized CSV value, and whether an update was issued. After write, re-read the RG tags and confirm the normalized value is present (already implemented in `Sync-ResourceGroupTags`).

## Conventions for future changes

- Keep the managed-keys list in exactly one place: `$script:ManagedKeys` in `Invoke-TagReconciliation.ps1`. If the list changes, update the [Managed tag keys](#managed-tag-keys) section here and add a Change log entry.
- Normalization rules live in `ConvertTo-NormalizedTagValue`. Any change to trimming/casing must update the [Value normalization](#value-normalization) section and the Change log.
- The pipeline must remain secret-free — no app secrets, no PATs, no connection strings in variables. Auth stays on the federated UAMI service connection.
- Default `whatIf` on the schedule stays `true`. Writes are opt-in via a manual queue.
- Every material change to `pipelines/`, `scripts/`, or the spec above must add a dated entry to the Change log below.

## Change log

Newest first. One entry per change. Format: `YYYY-MM-DD — <short summary>`, followed by a short bullet list of what changed and why.

- 2026-09-18 — Fix `nextLink` StrictMode crash in `Get-SubscriptionsUnderManagementGroup`.
  - `scripts/Invoke-TagReconciliation.ps1` — probe `$resp.PSObject.Properties.Name -contains 'nextLink'` before reading `$resp.nextLink`. Under `Set-StrictMode -Version Latest`, a single-page descendants response (no `nextLink` in the JSON) was throwing `The property 'nextLink' cannot be found on this object.`
  - No behavior change for multi-page responses; only difference is that single-page responses no longer crash the run.
- 2026-09-18 — Switch match key from `ResourceGroupName` to `SubscriptionName` (subscription display name).
  - `scripts/Invoke-TagReconciliation.ps1` — `New-CsvIndex` now requires a `SubscriptionName` column instead of `ResourceGroupName`; the index is keyed by subscription display name (case-insensitive, trimmed, lower-cased). `Get-SubscriptionsUnderManagementGroup` now returns `{Id, Name}` objects instead of bare GUIDs (using `properties.displayName` from the descendants API). Main loop matches on subscription name; every RG in a matched subscription receives the CSV row's tag values. Subscriptions not in the CSV are skipped before `Set-AzContext`.
  - `$stats` now tracks `subsInspected / subsMatched / subsSkipped` in addition to `rgsInspected / rgsUpdated / rgsUnchanged`; the trailing `rgsMatched` counter was dropped because in this design every inspected RG is a matched RG.
  - Rationale: FinOps ownership in this environment is defined at subscription granularity, not per RG. Matching on subscription display name (not GUID) keeps the CSV human-readable and stable across tenant moves.
  - Per-key diff-and-merge in `Sync-ResourceGroupTags` is unchanged: only keys whose current value differs from the normalized CSV value are written.
  - CSV contract in this spec and `README.md` updated accordingly.
- 2026-09-18 — Log Graph URLs in `Get-CsvFromSharePoint` for pipeline debugging.
  - `scripts/Invoke-TagReconciliation.ps1` now writes `GET <siteUri>`, the resolved `siteId`, and `GET <downloadUri>` to the host stream before the two Graph calls that resolve the site and download the CSV.
  - Purpose: 404s and 401/403s from Graph are hard to diagnose without seeing the exact URLs — this puts them into the ADO run log without changing any control flow.
- 2026-09-17 — Added placeholder pipeline variables inline.
  - `pipelines/azure-pipelines.yml` now defines `serviceConnectionName`, `sharePointHostname`, `sharePointSitePath`, `csvItemPath`, and `managementGroupId` under `variables:` with `dummy-*` values so the YAML validates on its own.
  - These are placeholders only — the pipeline's own **Variables** section (ADO UI) is expected to override each before the first real run. Do not commit real values here; the YAML defaults are for scaffolding, not for production.
- 2026-09-17 — Dropped variable group; config lives on the pipeline itself.
  - Removed `- group: finops-tag-reconciliation` from `pipelines/azure-pipelines.yml`. The five settings (`serviceConnectionName`, `sharePointHostname`, `sharePointSitePath`, `csvItemPath`, `managementGroupId`) are now defined in the ADO pipeline's own Variables section.
  - Updated the README and this spec to describe the new setup path.
- 2026-09-17 — Rewrote `claude.md` to reflect the shipped solution.
  - Replaced the "greenfield" placeholder with a description of the actual pipeline and PowerShell script, including CSV contract, pagination, verification, and pipeline parameter/variable-group shape.
  - Added this Change log section and the convention that all future changes get recorded here.
