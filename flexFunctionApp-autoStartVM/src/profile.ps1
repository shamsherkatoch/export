# Runs once when the PowerShell worker starts (cold start).
# Uses the User-Assigned Managed Identity attached to the Function App.

$ErrorActionPreference = 'Stop'

if ($env:MSI_SECRET -and (Get-Module -ListAvailable Az.Accounts)) {
    $uamiClientId = $env:UAMI_CLIENT_ID
    $subscriptionId = $env:TARGET_SUBSCRIPTION_ID

    if ([string]::IsNullOrWhiteSpace($uamiClientId)) {
        throw 'UAMI_CLIENT_ID app setting is missing.'
    }

    Disable-AzContextAutosave -Scope Process | Out-Null

    $connectArgs = @{
        Identity   = $true
        AccountId  = $uamiClientId
    }
    if (-not [string]::IsNullOrWhiteSpace($subscriptionId)) {
        $connectArgs['Subscription'] = $subscriptionId
    }

    Connect-AzAccount @connectArgs | Out-Null
}
