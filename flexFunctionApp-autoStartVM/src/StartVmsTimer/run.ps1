param($Timer)

$ErrorActionPreference = 'Stop'

$storageAccountName = $env:STORAGE_ACCOUNT_NAME
$blobEndpoint       = $env:STORAGE_BLOB_ENDPOINT
$containerName      = $env:VMLIST_CONTAINER
$blobName           = $env:VMLIST_BLOB
$defaultSubId       = $env:TARGET_SUBSCRIPTION_ID
$uamiClientId       = $env:UAMI_CLIENT_ID

foreach ($pair in @{
    STORAGE_ACCOUNT_NAME = $storageAccountName
    VMLIST_CONTAINER     = $containerName
    VMLIST_BLOB          = $blobName
    UAMI_CLIENT_ID       = $uamiClientId
}.GetEnumerator()) {
    if ([string]::IsNullOrWhiteSpace($pair.Value)) {
        throw "Required app setting '$($pair.Key)' is not set."
    }
}

if ([string]::IsNullOrWhiteSpace($blobEndpoint)) {
    $blobEndpoint = "https://$storageAccountName.blob.core.windows.net/"
}
if (-not $blobEndpoint.EndsWith('/')) { $blobEndpoint += '/' }

Write-Information "Reading VM list from ${blobEndpoint}${containerName}/${blobName}"

$storageCtx = New-AzStorageContext -StorageAccountName $storageAccountName -UseConnectedAccount
$tempFile   = Join-Path $env:TEMP ("vmList-{0}.json" -f ([guid]::NewGuid()))

try {
    Get-AzStorageBlobContent `
        -Context   $storageCtx `
        -Container $containerName `
        -Blob      $blobName `
        -Destination $tempFile `
        -Force | Out-Null

    $raw = Get-Content -Path $tempFile -Raw
} finally {
    if (Test-Path $tempFile) { Remove-Item $tempFile -Force -ErrorAction SilentlyContinue }
}

$parsed = $raw | ConvertFrom-Json

$entries = if ($parsed -is [System.Collections.IEnumerable] -and -not ($parsed -is [string])) {
    $parsed
} elseif ($parsed.PSObject.Properties.Name -contains 'vms') {
    $parsed.vms
} else {
    throw 'vmList.json must be a JSON array or an object with a "vms" array.'
}

if (-not $entries -or $entries.Count -eq 0) {
    Write-Warning 'VM list is empty. Nothing to start.'
    return
}

$grouped = $entries | Group-Object -Property {
    if ($_.subscriptionId) { $_.subscriptionId } else { $defaultSubId }
}

$results = New-Object System.Collections.Generic.List[object]

foreach ($subGroup in $grouped) {
    $subId = $subGroup.Name
    if ([string]::IsNullOrWhiteSpace($subId)) {
        throw 'VM entry missing subscriptionId and TARGET_SUBSCRIPTION_ID app setting is not set.'
    }

    Write-Information "Switching context to subscription $subId"
    Set-AzContext -Subscription $subId -Tenant (Get-AzContext).Tenant.Id | Out-Null

    foreach ($vm in $subGroup.Group) {
        $rg = $vm.resourceGroupName
        $name = $vm.vmName

        if ([string]::IsNullOrWhiteSpace($rg) -or [string]::IsNullOrWhiteSpace($name)) {
            $results.Add([pscustomobject]@{ vm = $name; rg = $rg; status = 'Skipped'; reason = 'Missing name or resource group' })
            continue
        }

        try {
            $status = Get-AzVM -ResourceGroupName $rg -Name $name -Status -ErrorAction Stop
            $powerState = ($status.Statuses | Where-Object Code -like 'PowerState/*' | Select-Object -First 1).Code

            if ($powerState -eq 'PowerState/running' -or $powerState -eq 'PowerState/starting') {
                Write-Information "$name in $rg is already $powerState — skipping."
                $results.Add([pscustomobject]@{ vm = $name; rg = $rg; status = 'AlreadyRunning'; powerState = $powerState })
                continue
            }

            Write-Information "Starting $name in $rg (current: $powerState)"
            Start-AzVM -ResourceGroupName $rg -Name $name -NoWait -ErrorAction Stop | Out-Null
            $results.Add([pscustomobject]@{ vm = $name; rg = $rg; status = 'StartRequested'; previousPowerState = $powerState })
        }
        catch {
            Write-Error "Failed to start ${name} in ${rg}: $($_.Exception.Message)"
            $results.Add([pscustomobject]@{ vm = $name; rg = $rg; status = 'Failed'; error = $_.Exception.Message })
        }
    }
}

$summary = $results | Group-Object status | ForEach-Object { "$($_.Name)=$($_.Count)" }
Write-Information ("StartVmsTimer completed: {0}" -f ($summary -join ', '))

if ($results | Where-Object status -eq 'Failed') {
    throw 'One or more VMs failed to start. See logs for details.'
}
