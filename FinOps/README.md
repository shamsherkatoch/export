# FinOps - Azure RG Tag Reconciliation

Reconcile Azure resource-group tags against a SharePoint-hosted CSV that is the source of truth for four FinOps tag values. An Azure DevOps pipeline runs a PowerShell task on a Microsoft-hosted agent, authenticates as a User-Assigned Managed Identity (UAMI) via a federated service connection, reads the CSV through Microsoft Graph, merges tag values onto every matching resource group under a target management group, and emails an HTML report of the run through Microsoft Graph.

## What it does

- Pulls a CSV from SharePoint via Microsoft Graph.
- Builds a nested index keyed by the pair **`(SubscriptionName, ResourceGroupName)`** - both case-insensitive and lower-cased. Every CSV row targets exactly one RG in exactly one subscription.
- Enumerates every subscription under the configured management group (both id and display name captured from the descendants API).
- For each subscription whose display name appears in the CSV, opens context on it and lists its RGs.
- For each RG whose `(sub, rg)` pair is in the CSV, compares the four managed tag values (`BusinessUnit`, `CostObject`, `GeneralLedgerCode`, `FinancialDelegate`) after normalization (strip all whitespace, uppercase invariant) and merges only the keys whose current value differs from the CSV. Unmanaged tags on the RG are left untouched.
- Re-reads the RG after writing and asserts the values took.
- Prints a summary: `subs inspected/matched/skipped` and `rgs inspected/matched/updated/unchanged`.
- On a successful run, renders an HTML report (run metadata, the summary counts, and a row per changed tag showing subscription, RG, key, current value, CSV value) and emails it through Microsoft Graph `sendMail` using the same UAMI token.

Subscriptions whose display name is not in the CSV are skipped entirely - the script does not enter them or list their RGs. Inside a matched subscription, RGs whose name isn't in that subscription's CSV rows are left alone.

## Repository layout

```
FinOps/
├── README.md                              # This file - overview and operating notes
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

### 1. Pipeline variables

Define these directly on the pipeline (**Pipelines → select the pipeline → Edit → Variables**). No variable group and no YAML `variables:` block - all values are held in the pipeline's own Variables section. None are secrets; leave the "Keep this value secret" checkbox off unless your org policy requires otherwise.

| Variable | Example | Purpose |
| --- | --- | --- |
| `serviceConnectionName` | `finops-uami-federated` | ADO service connection (federated) backed by the UAMI. |
| `sharePointHostname` | `contoso.sharepoint.com` | Host of the SharePoint tenant. |
| `sharePointSitePath` | `/sites/finops` | Server-relative site path. |
| `csvItemPath` | `Shared Documents/finops/tags.csv` | Drive-root-relative path to the CSV. |
| `managementGroupId` | `mg-contoso-root` | Management group **name** (not display name). |
| `mailFrom` | `finops-reports@contoso.com` | Mailbox the HTML report is sent **from**. UPN or object id of a real Exchange Online mailbox. |
| `mailTo` | `finops@contoso.com; cloudops@contoso.com` | Report recipients. **Multiple addresses are supported** - separate them with `;` or `,`. |
| `mailSubject` | `Azure RG tag reconciliation` | Subject line base. The script appends the run mode and change count. |

The pipeline YAML references each as `$(name)` and expects them to resolve at queue time - a missing variable fails the run at the `AzurePowerShell@5` step with an empty-argument error.

`mailTo` is the only optional one: leave it empty and the run reconciles as normal, logs `Email report skipped - no MailTo recipients configured`, and sends nothing. If `mailTo` is set but `mailFrom` is empty the script throws, because Graph app-only `sendMail` has no implicit sender.

The final subject is `<mailSubject> - LIVE - <n> RG(s) changed`. Mail is only sent on live runs (`whatIf = false`); dry runs log `Email report skipped - WhatIfMode is on (dry run).` and send nothing, and don't check `mailFrom`/`mailTo` either.

### 2. UAMI and federated service connection

- Create a User-Assigned Managed Identity in a suitable subscription.
- In Azure DevOps, create a **workload identity federation (automatic or manual)** service connection that federates back to that UAMI. Name it to match `serviceConnectionName` above.

### 3. UAMI access

The service connection is backed by the UAMI, so every RBAC/Graph grant below is assigned to the UAMI's object (as principalId in `New-AzRoleAssignment`, or as the app in Graph). Assign at the **management group** scope so it inherits down to every subscription/RG the pipeline touches - do not assign per subscription.

#### 3a. Azure Resource Manager (management group + everything under it)

Assign these built-in roles to the UAMI at scope `/providers/Microsoft.Management/managementGroups/{managementGroupId}`:

| Role | Why this script needs it | Key actions it grants |
| --- | --- | --- |
| **Reader** | Enumerate the MG's subscription tree, load RGs and their current tags. | `Microsoft.Management/managementGroups/read`, `Microsoft.Management/managementGroups/descendants/read`, `Microsoft.Resources/subscriptions/read`, `Microsoft.Resources/subscriptions/resourceGroups/read` (Reader is `*/read`, so all of these are covered). |
| **Tag Contributor** | Merge managed tag keys onto matching RGs and re-read to verify. | `Microsoft.Resources/tags/*` (read + write + delete on tags), plus `Microsoft.Resources/subscriptions/resourceGroups/read` so it can target the RG. |

Concrete actions the script exercises (all covered by the two roles above):

- `Microsoft.Management/managementGroups/read` - resolve the MG.
- `Microsoft.Management/managementGroups/descendants/read` - `GET .../managementGroups/{id}/descendants` to list subscriptions.
- `Microsoft.Resources/subscriptions/read` - `Set-AzContext -SubscriptionId ...`.
- `Microsoft.Resources/subscriptions/resourceGroups/read` - `Get-AzResourceGroup` + post-write re-read.
- `Microsoft.Resources/tags/read` - read existing tag hashtable before diffing.
- `Microsoft.Resources/tags/write` - `Update-AzTag -Operation Merge`.

Do **not** grant `Contributor` or `Owner` - Tag Contributor is the least-privileged write role that satisfies this workload. Do **not** grant `Microsoft.Authorization/*/write` - the pipeline never edits role assignments. If you build a custom role instead of using Tag Contributor, its `actions` must include everything in the bullet list above and the `notActions` must not exclude `Microsoft.Resources/tags/write`.

Reference PowerShell to grant them (run once, per MG):

```powershell
$mgScope   = "/providers/Microsoft.Management/managementGroups/<managementGroupId>"
$uamiObjId = "<UAMI principalId (objectId of the managed identity)>"

New-AzRoleAssignment -ObjectId $uamiObjId -RoleDefinitionName "Reader"          -Scope $mgScope
New-AzRoleAssignment -ObjectId $uamiObjId -RoleDefinitionName "Tag Contributor" -Scope $mgScope
```

#### 3b. Microsoft Graph → SharePoint (CSV read)

The UAMI needs Graph permission to download the CSV. The pipeline uses **`Sites.Selected`** (application permission), which grants access to **only** the specific SharePoint site you scope it to - not every site in the tenant. There are two grants to do, in order:

1. **Tenant-level**: give the UAMI's service principal the `Sites.Selected` app permission on Microsoft Graph, and admin-consent it. This unlocks the *ability* to be granted per-site access, but on its own confers zero site access.
2. **Site-level**: grant the UAMI `read` on the one SharePoint site that holds the CSV, via `POST /sites/{siteId}/permissions`. Only after this step will the pipeline be able to fetch the file.

`read` is sufficient - the script only downloads the file, it never writes back. Use `write` only if a future workload updates the CSV from Azure.

##### Values you need before you start

Collect these once and reuse them. All lookups use PowerShell: `Az.ManagedServiceIdentity` for the UAMI and `Microsoft.Graph.Applications` for Graph. Install once with:

```powershell
Install-Module Az.ManagedServiceIdentity, Microsoft.Graph.Applications, Microsoft.Graph.Sites -Scope CurrentUser
```

| Value | Where to find it |
| --- | --- |
| **UAMI `clientId`** (aka `appId`) | Azure Portal → the Managed Identity → Overview → **Client ID**. Also `(Get-AzUserAssignedIdentity -Name <uami> -ResourceGroupName <rg>).ClientId`. |
| **UAMI `objectId`** (service principal id in Entra) | Azure Portal → the Managed Identity → Overview → **Object (principal) ID**. Also `(Get-AzUserAssignedIdentity -Name <uami> -ResourceGroupName <rg>).PrincipalId`. |
| **UAMI display name** | The Managed Identity's name - used only as a label in the Graph permissions payload. |
| **Microsoft Graph service principal `objectId`** in your tenant | `(Get-MgServicePrincipal -Filter "appId eq '00000003-0000-0000-c000-000000000000'").Id` (the `00000003-…` app id is Microsoft Graph, the same in every tenant; the service principal's object id is per-tenant). |
| **`Sites.Selected` app-role id** | `9492366f-7969-46a4-8d15-ed1a20078fff` - same in every tenant, no need to look it up. |
| **`siteId`** for the SharePoint site | Resolve via Graph - see step 2 below. Format is `{host},{siteCollectionGuid},{siteGuid}`. |

You'll need a signed-in admin (either an Entra admin who can grant app-role assignments and admin-consent Graph permissions, or a SharePoint admin / site owner who can grant site permissions - usually the same person can do both). The pipeline's UAMI cannot grant these permissions to itself; a human runs this once.

Sign in once at the top of the session and reuse the connection for every step below:

```powershell
Connect-AzAccount                              # for Az.ManagedServiceIdentity lookups
Connect-MgGraph -Scopes `
  "AppRoleAssignment.ReadWrite.All", `
  "Application.Read.All", `
  "Sites.FullControl.All"                      # required to POST /sites/{id}/permissions
```

##### Step 1 - Grant `Sites.Selected` at the tenant and admin-consent it

Assigns the Graph `Sites.Selected` app role to the UAMI's service principal. Do this once per UAMI.

```powershell
$uamiObjectId      = "e1856993-XXXXX-ZZZZ"   # principalId of the managed identity
$graphSp           = Get-MgServicePrincipal -Filter "appId eq '00000003-0000-0000-c000-000000000000'"
$sitesSelectedRole = $graphSp.AppRoles | Where-Object { $_.Value -eq "Sites.Selected" }

New-MgServicePrincipalAppRoleAssignment `
  -ServicePrincipalId $uamiObjectId `
  -PrincipalId        $uamiObjectId `
  -ResourceId         $graphSp.Id `
  -AppRoleId          $sitesSelectedRole.Id
```

A successful call returns an `appRoleAssignment` object. Because you granted an *application* permission directly to a service principal, this **is** the admin consent - there is no separate "Grant admin consent" click for managed identities.

**Verify**: the assignment should show up under **Entra ID → Enterprise applications → (the UAMI) → Permissions**, listing `Sites.Selected` on `Microsoft Graph` as admin-consented. Or from PowerShell:

```powershell
Get-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $uamiObjectId |
  Where-Object { $_.ResourceId -eq $graphSp.Id } |
  Select-Object PrincipalDisplayName, AppRoleId, ResourceDisplayName
```

##### Step 2 - Resolve the `siteId` of the target SharePoint site

Every site-level grant needs the site's Graph id. Do this once per site (any Graph-permitted admin identity can call it - you're not using the UAMI yet):

```powershell
$sharePointHostname = "mycloudgurucom.sharepoint.com"
$sharePointSitePath = "/sites/mycloudguru"

$site   = Invoke-MgGraphRequest -Method GET `
  -Uri "https://graph.microsoft.com/v1.0/sites/${sharePointHostname}:${sharePointSitePath}"
$siteId = $site.id
$siteId

```

The pipeline script does the same lookup at runtime, so the UAMI itself doesn't need this value stored anywhere - it's only used in step 3.

##### Step 3 - Grant the UAMI `read` on that one site

`POST /sites/{siteId}/permissions` gives the UAMI's application the actual per-site access. Without this, `Sites.Selected` alone still returns `403` on every site.

```powershell
$uamiClientId = "183dd23f-XXXXX-YYYY"
$uamiName     = "uami-finops"

$body = @{
  roles               = @("read","write")
  grantedToIdentities = @(
    @{ application = @{ id = $uamiClientId; displayName = $uamiName } }
  )
} | ConvertTo-Json -Depth 5

$grant = Invoke-MgGraphRequest -Method POST `
  -Uri  "https://graph.microsoft.com/v1.0/sites/$siteId/permissions" `
  -Body $body -ContentType "application/json"

$grant.id   # note this - needed only to revoke later
```

You don't need to keep the permission id, but noting it makes revocation easier later:

```powershell
Invoke-MgGraphRequest -Method DELETE `
  -Uri "https://graph.microsoft.com/v1.0/sites/$siteId/permissions/$($grant.id)"
```

##### Step 4 - Verify the pipeline can actually read the file

Impersonation isn't possible for a managed identity from your laptop, so the cleanest verification is to run the pipeline in dry-run mode (`whatIf = true`, the default). A successful run logs the CSV source URL and row count in its preamble - that proves the whole chain (tenant grant → site grant → file fetch) works. If Graph returns 401/403 there, jump to the [Common failure modes](#common-failure-modes) section for the fix path.

#### 3c. Microsoft Graph → Exchange Online (send the HTML report)

The UAMI sends the report itself - there is no SMTP account, no app password, no shared secret. It calls `POST /v1.0/users/{mailFrom}/sendMail` with the same token type used for SharePoint, so the only new thing to grant is the **`Mail.Send` application permission**, plus a scoping policy so the UAMI can send as *one* mailbox rather than the whole tenant.

| What | Value |
| --- | --- |
| Graph application permission | `Mail.Send` |
| App-role id (same in every tenant) | `b633e1c5-b582-4048-a93e-9f11b44c7e96` |
| Graph call the script makes | `POST https://graph.microsoft.com/v1.0/users/{mailFrom}/sendMail` |
| Sender requirement | `mailFrom` must be a real Exchange Online mailbox (licensed user or shared mailbox). A mail-enabled security group or a distribution list will **not** work as the sender. |

> **Read this before granting.** `Mail.Send` as an *application* permission lets the identity send mail as **any mailbox in the tenant** by default. That is far wider than this pipeline needs. Step 2 below narrows it to the single `mailFrom` mailbox with an Exchange application access policy - treat that step as mandatory, not optional.

##### Step 1 - Grant `Mail.Send` to the UAMI

Same shape as the `Sites.Selected` grant in 3b; reuse the `$uamiObjectId` and `$graphSp` from that session.

```powershell
$uamiObjectId = "e1856993-XXXXX-ZZZZ"   # principalId of the managed identity
$graphSp      = Get-MgServicePrincipal -Filter "appId eq '00000003-0000-0000-c000-000000000000'"
$mailSendRole = $graphSp.AppRoles | Where-Object { $_.Value -eq "Mail.Send" }

New-MgServicePrincipalAppRoleAssignment `
  -ServicePrincipalId $uamiObjectId `
  -PrincipalId        $uamiObjectId `
  -ResourceId         $graphSp.Id `
  -AppRoleId          $mailSendRole.Id
```

As with `Sites.Selected`, assigning an application permission directly to a service principal **is** the admin consent - there is no separate consent click for managed identities.

**Verify**: **Entra ID → Enterprise applications → (the UAMI) → Permissions** should now list both `Sites.Selected` and `Mail.Send` on Microsoft Graph.

##### Step 2 - Scope the grant to your existing sender mailbox

Step 1 left the UAMI able to send as **any** mailbox in the tenant. This step restricts it to the one existing mailbox you want the reports to come from - the value you put in the `mailFrom` pipeline variable.

You do **not** need to create a distribution group or a mail-enabled security group for this. `-PolicyScopeGroupId` accepts any recipient, including a single user or shared mailbox, so point it straight at the mailbox you already have.

Requires the `ExchangeOnlineManagement` module and an Exchange admin:

```powershell
Install-Module ExchangeOnlineManagement -Scope CurrentUser
Connect-ExchangeOnline

# The UAMI clientId, NOT the objectId used for role assignments.
$uamiClientId = "183dd23f-XXXXX-YYYY"

# The existing mailbox the reports send from - same value as the mailFrom variable.
$senderMailbox = "admin@contoso.com"

New-ApplicationAccessPolicy `
  -AppId              $uamiClientId `
  -PolicyScopeGroupId $senderMailbox `
  -AccessRight        RestrictAccess `
  -Description        "Limit FinOps tag pipeline to the report sender mailbox"
```

Two things to get right:

- **`-AppId` is the UAMI's clientId**, the same value used in the `POST /sites/{siteId}/permissions` body in 3b - not the principal/object id used for role assignments. This is the most common cause of a `403` on `sendMail`, because a policy built on the wrong id silently applies to nothing.
- **`-PolicyScopeGroupId` must be the mailbox itself**, and `mailFrom` must match it. The policy is an allow-list: anything not in scope is denied.

If you later want reports to be sendable from more than one mailbox, that is when a mail-enabled security group is worth creating - put the mailboxes in it and pass the group here instead. For a single sender it adds an object to maintain and buys nothing.

Policies take up to ~30 minutes to propagate. Test once it is live:

```powershell
Test-ApplicationAccessPolicy -Identity $senderMailbox -AppId $uamiClientId
# AccessCheckResult : Granted

Test-ApplicationAccessPolicy -Identity "someone-else@contoso.com" -AppId $uamiClientId
# AccessCheckResult : Denied   <- this result is what proves the scoping works
```

Run both checks. `Granted` alone only shows the mailbox is reachable; the `Denied` on an unrelated mailbox is what proves the tenant-wide `Mail.Send` grant is actually contained.

##### Step 3 - Verify end to end

Mail is only sent on live runs, so queue the pipeline with `whatIf = false` (scope the CSV down first if you don't want real tag writes during the test). The tail of the log prints `POST https://graph.microsoft.com/v1.0/users/...:/sendMail` followed by `Report sent.`, and the report lands in every `mailTo` inbox. A `403 ErrorAccessDenied` at that step means the app access policy is denying the sender - re-check that `-AppId` is the clientId and that `-PolicyScopeGroupId` names the same mailbox as `mailFrom`.

#### 3d. Azure DevOps

The workload-identity service connection (`serviceConnectionName`) must be **authorized for the pipeline** (either at project level or via a pipeline-scoped grant). No further ADO role beyond that is required on the UAMI.

### 4. CSV shape

CSV in SharePoint must have (at minimum) these headers:

```
SubscriptionName,ResourceGroupName,BusinessUnit,CostObject,GeneralLedgerCode,FinancialDelegate
```

Match is by the pair `(SubscriptionName, ResourceGroupName)`. `SubscriptionName` is the subscription's **display name** as shown in the Azure portal / `descendants` API. Each CSV row applies to exactly one RG in exactly one subscription - no wildcards, no cross-subscription broadcasts.

Rows with an empty `SubscriptionName` or `ResourceGroupName` are skipped. Missing required columns cause `New-CsvIndex` to throw and fail the run. Duplicate `(SubscriptionName, ResourceGroupName)` pairs silently let the later row win - deduplicate at the source. Extra columns (e.g. `SubscriptionId` kept for humans, `Owner`, `Notes`) are ignored.

## Running the pipeline

### Scheduled (default)

The `schedules:` block queues the pipeline daily at 06:00 UTC against `main`. It runs with `whatIf = true`, so nothing is written and no email is sent - the run logs what would change. Read the run log as the drift report.

### Ad-hoc dry run

Queue the pipeline manually from ADO. Leave the `whatIf` parameter checked. Same behavior as the scheduled run: log only, no writes, no email.

### Real write

Queue the pipeline manually and **uncheck `whatIf`** (or set it to `false`). The task then calls `Update-AzTag ... -Operation Merge`, verifies each written value, and emails the HTML report.

## Operating notes

### Reading a run

- **Preamble**: source URL of the CSV, row count, unique RG-tuple count, subscription count.
- **Per subscription**: `=== Subscription: <guid> ===`, then per RG that matched a CSV row: one line per managed key, either `match ('X')` or `'old' -> 'new'`. RGs with no diffs log `no changes`.
- **Write mode**: `merged N key(s) OK` after each successful write. If verify fails, the run throws immediately.
- **Dry-run mode**: `WhatIf: would merge N key(s)` instead of a write.
- **Summary line** at the end: `Summary: inspected=X, matched=Y, updated=Z, unchanged=W`. `updated + unchanged = matched`. `matched ≤ inspected`.
- **Report** (live runs only): the last lines show the recipient list and the `sendMail` POST. Dry runs end with `Email report skipped - WhatIfMode is on (dry run).` Mail goes out only after the reconciliation loop finished without throwing, so receiving the report is itself the signal that the run succeeded - a run that dies mid-way sends nothing and fails the ADO task instead.

### The emailed report

Sent on every successful **live** run (`whatIf = false`). Dry runs, including the daily schedule, send nothing. It contains:

- **Header** - `LIVE - tags were merged` (green).
- **Run metadata** - UTC timestamp, management group, CSV source URL.
- **Summary** - the same seven counters printed in the log.
- **Changes table** - one row per changed tag key: subscription, resource group, tag key, current Azure value, CSV value. The heading reads `Changed (n resource group(s))`. Tags with no current value show `(not set)`. If nothing differs, the table is replaced with a single "No tag differences found" line.

All values are HTML-encoded, so a stray `&` or `<` in a tag value cannot break the layout.

### Turning drift into a real update

1. Run the pipeline in dry-run mode and inspect the log to confirm the planned changes are what you expect.
2. If OK, queue a run with `whatIf = false`. Consider scoping the CSV first if the change set is large - the script has no built-in filter, so the CSV itself is the scope control.
3. After the write run, spot-check a few RGs in the portal, or diff the run's summary against the previous day's dry-run summary.

### Common failure modes

- **`Set-AzContext failed` on a subscription** - the UAMI likely lacks Reader on that subscription, or the subscription is disabled. Fix the role assignment; the script continues past the subscription and prints a warning.
- **`CSV is missing required column`** - a header was renamed or removed. Fix the CSV; do not edit the script to accept the new name 
- **`Verify failed for <RG>`** - the RG was written but the re-read did not observe the expected value. Usually caused by a concurrent tag write from another process. Re-run; if it persists, investigate the other writer.
- **401/403 from Graph on the site fetch** - the UAMI is missing `Sites.Selected` consent or does not have `read` on the specific site. Re-grant via `POST /sites/{siteId}/pewritermissions`.
- **Duplicate `(SubscriptionName, ResourceGroupName)` rows in CSV** - the last row wins (later rows overwrite earlier ones in `$index`). Deduplicate at the source.
- **Subscription display name changed and CSV wasn't updated** - the subscription silently drops out of scope (logged as `skipped - SubscriptionName '...' not in CSV`). Rename the CSV row to match, or rename the subscription back.
- **RG renamed and CSV wasn't updated** - the CSV still targets the old name, so both the old CSV row and the new RG go untouched. Fix the CSV to reference the current RG name.
- **`403 ErrorAccessDenied` on `sendMail`** - the Exchange application access policy is blocking the sender. Confirm `New-ApplicationAccessPolicy` was created with the UAMI's **clientId** (not its objectId) and that `-PolicyScopeGroupId` names the same mailbox as `mailFrom`: `Test-ApplicationAccessPolicy -Identity <mailFrom> -AppId <clientId>` must return `Granted`. Allow ~30 minutes after creating or editing a policy.
- **`404 (Not Found)` on `sendMail`** - about the **sender**, not the recipients and not the `Mail.Send` grant (a missing grant fails 403). `mailFrom` must resolve to a user object in this tenant - check the domain is one the tenant actually owns - and must have an Exchange Online mailbox; an unlicensed user, a distribution list and a mail-enabled security group all 404, a shared mailbox is fine. The log prints the Graph error alongside the failure; confirm with `Get-Mailbox <mailFrom>`.
- **`401`/`403` immediately on `sendMail` but SharePoint worked** - `Mail.Send` was never granted, only `Sites.Selected`. Re-run step 1 of section 3c; the two grants are independent.
- **Run succeeded but no email arrived** - check whether the log says `Email report skipped - no MailTo recipients configured`; that means the `mailTo` pipeline variable is empty or missing. Otherwise check the recipients' junk folders, since the sending mailbox is likely new.
- **`MailTo was supplied but MailFrom is empty`** - the `mailFrom` pipeline variable is unset. Graph app-only send has no default sender mailbox; set it explicitly.

