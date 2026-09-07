# CLAUDE.md — functionApp-autoStartVM

Guidance for future Claude sessions working in this directory.

## What this project is

Azure **Flex Consumption** Function App (PowerShell 7.4) that starts VMs on a
timer. Everything is private: storage + Function App both sit behind private
endpoints; the app egresses through a VNet-integrated subnet. The VM list lives
as JSON in the same storage account the Flex app uses for its deployment
container. Infra is Bicep, deployed by an Azure DevOps YAML pipeline.

## Directory layout

```
infra/
  main.bicep                # RG-scoped orchestrator, wires modules together
  main.bicepparam           # per-env values (Bicep-typed parameter file)
  modules/
    network.bicep           # VNet + snet-pe + snet-integration (delegated)
    storage.bicep           # SA (private), containers, blob PE + DNS zone
    identity.bicep          # UserAssignedIdentity (the "UAMI")
    monitoring.bicep        # Log Analytics + workspace-based App Insights
    functionApp.bicep       # FC1 plan, site, VNet integration, sites PE
    roleAssignments.bicep   # RBAC on storage + fan-out to VM RGs
    vmRoleAssignment.bicep  # single "VM Contributor" grant, called per RG
src/                        # Azure Functions v4 project
  host.json
  requirements.psd1         # Az.Accounts / Az.Compute / Az.Storage
  profile.ps1               # UAMI login (runs on cold start)
  StartVmsTimer/
    function.json           # timer binding, schedule = %START_VMS_SCHEDULE%
    run.ps1                 # the start-VMs logic
  local.settings.json.sample
config/
  vmList.sample.json        # example VM list; real one is uploaded to blob
pipelines/
  azure-pipelines.yml       # Validate + Deploy stages
README.md
CLAUDE.md                   # (this file)
```

## Key design decisions — don't casually change these

- **Flex Consumption only.** Plan SKU is `FC1` / tier `FlexConsumption`, site
  `kind: functionapp,linux`, and the site uses `properties.functionAppConfig`
  (`deployment`, `runtime`, `scaleAndConcurrency`) instead of the classic
  `siteConfig.linuxFxVersion`. This requires **Microsoft.Web API version
  `2024-11-01`**. Bicep prints `BCP081` warnings for that API — the local type
  index doesn't ship it yet but the deployment engine accepts it. Ignore those
  warnings; do not downgrade the API version.
- **Integration subnet delegation is `Microsoft.App/environments`.** That's the
  correct delegation for Flex VNet integration. Not `Microsoft.Web/serverFarms`.
- **No shared keys anywhere.** Storage has `allowSharedKeyAccess: false` and
  `publicNetworkAccess: Disabled`. The Function App reaches storage via
  identity-based settings (`AzureWebJobsStorage__blobServiceUri`,
  `__credential=managedidentity`, `__clientId=<UAMI clientId>`). The Flex
  deployment container is authenticated the same way
  (`functionAppConfig.deployment.storage.authentication.type =
  UserAssignedIdentity`). If you add a new storage-touching setting, keep this
  pattern — never re-introduce a connection string.
- **UAMI, not System-Assigned.** The identity is declared once in
  `identity.bicep` and referenced by the site (`identity.type: UserAssigned`),
  by the deployment-storage auth block, and by `keyVaultReferenceIdentity`. Its
  client id flows to the app as `UAMI_CLIENT_ID` and is what `profile.ps1` uses
  for `Connect-AzAccount -Identity -AccountId $uamiClientId`.
- **Timer schedule comes from an app setting**, not hard-coded in
  `function.json`. `function.json` references `%START_VMS_SCHEDULE%` (NCRONTAB,
  6 fields). Retune the schedule by updating the app setting / Bicep param;
  don't inline it back into `function.json`.
- **VM list schema is dual-shape.** `run.ps1` accepts both
  `{ "vms": [...] }` and a top-level array. Each entry: optional
  `subscriptionId`, required `resourceGroupName`, required `vmName`. Keep both
  shapes working if you touch the parser.
- **Role fan-out.** `roleAssignments.bicep` grants storage data roles at the
  storage-account scope, then loops `vmRoleAssignment.bicep` at each RG in
  `targetVmResourceGroupNames`. To let the app start VMs in a new RG, add it to
  that param — do not widen the role scope to the subscription.
- **Private DNS is created in-module.** `storage.bicep` and `functionApp.bicep`
  each create their `privatelink.*` zone + VNet link. If the target environment
  already has hub-managed zones, delete the local zone/link resources and point
  the private-endpoint DNS zone group at the hub zone id — do not leave two
  zones with the same name in different subscriptions.

## Environment variables the function reads

Set in Bicep (`functionApp.bicep` → `siteConfig.appSettings`). If you rename
one, update **both** the Bicep and `src/StartVmsTimer/run.ps1` (and
`profile.ps1` where applicable) — they are the contract.

| Setting                    | Read by            | Purpose                                        |
| -------------------------- | ------------------ | ---------------------------------------------- |
| `UAMI_CLIENT_ID`           | `profile.ps1`, `run.ps1` | Which identity to log in as / attribute to. |
| `STORAGE_ACCOUNT_NAME`     | `run.ps1`          | Passed to `New-AzStorageContext`.              |
| `STORAGE_BLOB_ENDPOINT`    | `run.ps1`          | Logged; also used to build blob URL.           |
| `VMLIST_CONTAINER`         | `run.ps1`          | Container holding `vmList.json`.               |
| `VMLIST_BLOB`              | `run.ps1`          | Blob name.                                     |
| `TARGET_SUBSCRIPTION_ID`   | `run.ps1`, `profile.ps1` | Default sub when a VM entry omits `subscriptionId`. |
| `TARGET_RESOURCE_GROUPS`   | (informational)    | CSV, useful for logs/support.                  |
| `START_VMS_SCHEDULE`       | `function.json`    | Timer schedule (NCRONTAB).                     |
| `AzureWebJobsStorage__*`   | Functions host     | Identity-based storage — do not replace with a connection string. |
| `APPLICATIONINSIGHTS_CONNECTION_STRING` + `APPLICATIONINSIGHTS_AUTHENTICATION_STRING` | Functions host | Managed-identity ingestion to App Insights. |

## Bicep parameters that matter

`infra/main.bicepparam`:

- `workloadName` + `environment` → name prefix `<workload>-<env>-…`.
- `vnetAddressPrefix`, `privateEndpointSubnetPrefix`, `integrationSubnetPrefix`
  — must be inside the VNet, must not collide with the hub.
- `instanceMemoryMB` ∈ {512, 2048, 4096} — Flex per-instance memory.
- `maximumInstanceCount` — Flex scale ceiling (≥ 40).
- `powerShellVersion` — allowed values gated to `7.4`.
- `startVmsSchedule` — 6-field NCRONTAB.
- `targetVmResourceGroupNames` — array of RG names in the current subscription
  where the UAMI gets `Virtual Machine Contributor`.

## Common tasks

**Compile Bicep locally**
```bash
cd infra && bicep build main.bicep --outfile /tmp/main.compiled.json
```

**What-if against a real RG**
```bash
az deployment group what-if -g rg-autostartvm-dev \
  -p infra/main.bicepparam
```

**Deploy manually**
```bash
az deployment group create -g rg-autostartvm-dev \
  -p infra/main.bicepparam
```

`.bicepparam` files carry their own `using` reference to `main.bicep`, so
`--template-file` (and the `@` prefix used with JSON param files) is not needed.
Individual overrides still compose: append `-p environment=prd` etc.

**Publish function code manually** (from `src/`)
```bash
func azure functionapp publish <functionAppName>
```
On Flex, the CLI uploads the package to the deployment container.

**Update the VM list**
```bash
az storage blob upload \
  --account-name <storageAccountName> --auth-mode login \
  --container-name config --name vmList.json \
  --file config/vmList.json --overwrite
```
No redeploy required — the timer re-reads the blob on every fire.

## Pipeline flow (`pipelines/azure-pipelines.yml`)

Two stages, both on `ubuntu-latest`:

1. **Validate** — installs Bicep, runs `bicep build`, then `az deployment group
   what-if` against the target RG.
2. **Deploy** — runs `az deployment group create`, reads outputs
   (`functionAppName`, `storageAccountName`, `configContainerName`,
   `vmListBlobName`) into pipeline variables via the `bicepDeploy` step name,
   uploads `config/vmList.json` (falls back to `vmList.sample.json`), installs
   Azure Functions Core Tools v4, zips `src/`, and publishes with
   `az functionapp deployment source config-zip --build-remote false`.

Service connection is `sc-azure-<env>`. Environment is `${{ parameters.environment }}`
(gives you approvals). The Deploy stage only runs off `main`.

## Gotchas

- **BCP081 warnings on `Microsoft.Web/*@2024-11-01` are expected.** Do not
  downgrade the API version to silence them — earlier versions don't expose
  `functionAppConfig` and the Flex site will fail to deploy.
- **`allowSharedKeyAccess: false` breaks anything that assumes a connection
  string.** The Functions host runtime works because of the identity-based
  `AzureWebJobsStorage__*` settings; any new binding that needs storage must
  use the same identity pattern.
- **Function App has `publicNetworkAccess: Disabled`.** You cannot browse the
  portal Kudu UI over the public internet. Use the private endpoint via a
  jumpbox / VPN / Bastion, or temporarily flip `publicNetworkAccess` to
  `Enabled` for debugging (then flip it back — do not commit the flip).
- **Timer schedule is NCRONTAB (6 fields, seconds-first).** UTC. Watch out
  when copying 5-field cron from the internet.
- **`Start-AzVM -NoWait`** is intentional — the function fires
  start requests in parallel and returns quickly. Success is measured by "start
  requested", not "VM reached running". If you need "wait until running",
  change to `-AsJob` + `Wait-Job` and mind the 10-minute `functionTimeout` in
  `host.json`.
- **The role assignments in `roleAssignments.bicep` require the deployer to
  have `Microsoft.Authorization/roleAssignments/write`** (User Access
  Administrator or Owner). A plain Contributor SPN will fail at that step.
- **`profile.ps1` runs on cold start only.** If you add long-running init,
  remember Flex Consumption cold-starts are user-visible.
- **Don't inline the VM list into Bicep params.** The whole point is that ops
  edits `vmList.json` in blob storage without a redeploy.

## When adding a new function

1. Create `src/<FunctionName>/function.json` + `run.ps1`.
2. If it needs new modules, add to `src/requirements.psd1` (managed
   dependencies).
3. If it needs new app settings, add them to `functionApp.bicep`
   `siteConfig.appSettings` — that is the single source of truth.
4. If it needs new RBAC, add it in `roleAssignments.bicep` (or a new module
   scoped appropriately) — never grant broader than needed.
5. Keep timer schedules in app settings, referenced with
   `%SETTING_NAME%` from `function.json`.

## When adding a new environment

1. Duplicate `main.bicepparam` → `main.<env>.bicepparam`, adjust addresses /
   names / target RGs. Update the `using './main.bicep'` line if the relative
   path changes.
2. Create AzDO environment `<env>` (for approvals).
3. Create service connection `sc-azure-<env>`.
4. Run the pipeline with `parameters.environment = <env>`.

## Out of scope for this project

- No stop-VM function yet — pattern would mirror `StartVmsTimer`, swapping
  `Start-AzVM` for `Stop-AzVM -Force`. Same VM list, likely a separate schedule
  app setting.
- No Key Vault. `keyVaultReferenceIdentity` on the site is pre-wired to the
  UAMI so KV references work if one is added later, but no vault is created.
- No custom DNS forwarders. Assumes the VNet uses Azure-provided DNS or has
  conditional forwarders to Azure DNS (168.63.129.16) — otherwise the private
  endpoints won't resolve.
