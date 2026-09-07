# functionApp-autoStartVM

Scheduled VM auto-start solution running on an Azure **Flex Consumption** Function App
(PowerShell 7.4). All ingress is private (VNet + Private Endpoints) and all
outbound traffic is routed through a delegated integration subnet. The VM list is
maintained as JSON in the same storage account the Function App uses for deployment
content.

## Architecture

```
                +--------------------------------------+
                |   Azure Subscription / Resource Group |
                |                                       |
                |   +-----------------------------+     |
                |   |   VNet 10.60.0.0/16         |     |
                |   |                             |     |
                |   |  snet-pe        10.60.1.0/24|<--+ |
                |   |   * Storage blob PE         |   | |
                |   |   * Function App sites PE   |   | |
                |   |                             |   | |
                |   |  snet-integration           |   | |
                |   |         10.60.2.0/24        |   | |
                |   |   (delegated to             |   | |
                |   |    Microsoft.App/environ.)  |   | |
                |   +-----------------------------+   | |
                |                                     | |
                |   +-----------------------------+   | |
                |   | Flex Consumption Plan (FC1) |   | |
                |   | Function App (PowerShell)   |---+ |
                |   |  - UserAssigned MI (UAMI)   |     |
                |   |  - VNet integrated          |     |
                |   |  - Public access disabled   |     |
                |   +--------------+--------------+     |
                |                  |                    |
                |   +--------------v--------------+     |
                |   | Storage Account (Priv)      |     |
                |   |   /app-package  (content)   |     |
                |   |   /config/vmList.json       |     |
                |   +-----------------------------+     |
                |                                       |
                |   Log Analytics + Application Insights|
                +--------------------------------------+
```

Timer-triggered function `StartVmsTimer`:
1. Cold-start: `profile.ps1` signs into Azure with the attached UAMI.
2. Reads `vmList.json` from the private storage account (managed identity, no keys).
3. Groups entries by subscription, then calls `Start-AzVM -NoWait` for anything
   that isn't already running or starting.
4. Summary + per-VM outcome logged to Application Insights.

## Repo layout

```
functionApp-autoStartVM/
  infra/
    main.bicep                       # orchestrator (RG scope)
    main.bicepparam                  # typed parameter file (Bicep syntax)
    modules/
      network.bicep                  # VNet + PE subnet + integration subnet
      storage.bicep                  # Storage, containers, blob PE + DNS
      identity.bicep                 # User-Assigned Managed Identity
      monitoring.bicep               # Log Analytics + App Insights
      functionApp.bicep              # Flex plan, site, VNet integration, sites PE
      roleAssignments.bicep          # RBAC on storage
      vmRoleAssignment.bicep         # VM Contributor per target RG
  src/
    host.json
    requirements.psd1                # Az.Accounts, Az.Compute, Az.Storage
    profile.ps1                      # UAMI login
    StartVmsTimer/
      function.json                  # timer binding, schedule from app setting
      run.ps1                        # start-VMs logic
    local.settings.json.sample
    .funcignore
    .gitignore
  config/
    vmList.sample.json               # example VM list schema
  pipelines/
    azure-pipelines.yml              # AzDO multi-stage pipeline
```

## VM list schema

`config/vmList.json` (uploaded to `config/vmList.json` in blob storage):

```json
{
  "vms": [
    { "subscriptionId": "…", "resourceGroupName": "rg-workloads-dev", "vmName": "vm-web-01" },
    { "resourceGroupName": "rg-workloads-dev", "vmName": "vm-app-01" }
  ]
}
```

- `subscriptionId` is optional; when omitted the function uses the
  `TARGET_SUBSCRIPTION_ID` app setting (defaults to the deployment subscription).
- Multiple VMs in one resource group, or spanning multiple resource groups /
  subscriptions, are all supported.
- A flat top-level JSON array is also accepted.

## Bicep parameters

Edit `infra/main.bicepparam` per environment. Key parameters:

| Parameter                     | Purpose                                                          |
| ----------------------------- | ---------------------------------------------------------------- |
| `workloadName`, `environment` | Name prefix (`<workload>-<env>-…`).                              |
| `vnetAddressPrefix`, `privateEndpointSubnetPrefix`, `integrationSubnetPrefix` | Networking. |
| `instanceMemoryMB`            | 512 / 2048 / 4096 — Flex per-instance memory.                    |
| `maximumInstanceCount`        | Flex scale ceiling.                                              |
| `powerShellVersion`           | `7.4`.                                                           |
| `startVmsSchedule`            | 6-field NCRONTAB (default `0 0 7 * * 1-5` — 07:00 weekdays UTC). |
| `targetVmResourceGroupNames`  | Resource groups where the UAMI is granted **Virtual Machine Contributor**. |

## Azure DevOps pipeline

`pipelines/azure-pipelines.yml` has two stages:

1. **Validate** — `bicep build` + `az deployment group what-if`.
2. **Deploy** — `az deployment group create`, upload `config/vmList.json` to the
   storage account with `--auth-mode login`, package `src/` and publish to the
   Flex Consumption Function App with `az functionapp deployment source config-zip`.

Prerequisites:
- Azure DevOps service connection named `sc-azure-<env>` bound to a service
  principal with **Contributor** + **User Access Administrator** (or the
  minimum set required to grant the role assignments) on the target subscription.
- Environment named `dev` / `tst` / `prd` in AzDO (for approvals).
- Populate `config/vmList.json` — the pipeline falls back to
  `vmList.sample.json` if it is missing, so the first deploy is not blocked.

## Manual deploy (from a workstation)

```bash
az group create -n rg-autostartvm-dev -l eastus
az deployment group create \
  -g rg-autostartvm-dev \
  -p infra/main.bicepparam
```

Then upload the VM list and publish the app:

```bash
az storage blob upload \
  --account-name <storageAccountName from output> \
  --auth-mode login \
  --container-name config --name vmList.json \
  --file config/vmList.json --overwrite

cd src && func azure functionapp publish <functionAppName from output>
```

## Managed identity + RBAC

The UAMI is granted:
- `Storage Blob Data Owner`, `Storage Blob Data Contributor`,
  `Storage Queue Data Contributor`, `Storage Table Data Contributor` on the
  storage account (needed for Flex deployment container, host runtime state,
  and reading `vmList.json`).
- `Virtual Machine Contributor` on each resource group listed in
  `targetVmResourceGroupNames`.

The Function App is configured with:
- `AzureWebJobsStorage__blobServiceUri` / `__credential=managedidentity` /
  `__clientId` — identity-based storage for host + triggers (no keys).
- `functionAppConfig.deployment.storage.authentication` =
  `UserAssignedIdentity` — the Flex deployment container is also read via UAMI.

## Local development

```bash
cp src/local.settings.json.sample src/local.settings.json
# fill in UAMI / storage / subscription values
cd src && func start
```

You'll need `az login` locally so the Az cmdlets can reach Azure with your
principal; `profile.ps1` skips UAMI login when `MSI_SECRET` is not set.
