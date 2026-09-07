param location string
param tags object
param planName string
param functionAppName string
param integrationSubnetId string
param privateEndpointSubnetId string
param vnetId string
param userAssignedIdentityResourceId string
param userAssignedIdentityClientId string
param storageAccountName string
param storageBlobEndpoint string
param deploymentContainerName string
param configContainerName string
param vmListBlobName string
param appInsightsConnectionString string
param instanceMemoryMB int
param maximumInstanceCount int
param powerShellVersion string
param startVmsSchedule string
param targetVmResourceGroupNames array

var subscriptionId = subscription().subscriptionId
var targetRgList = join(targetVmResourceGroupNames, ',')

resource plan 'Microsoft.Web/serverfarms@2024-11-01' = {
  name: planName
  location: location
  tags: tags
  kind: 'functionapp'
  sku: {
    name: 'FC1'
    tier: 'FlexConsumption'
  }
  properties: {
    reserved: true
  }
}

resource site 'Microsoft.Web/sites@2024-11-01' = {
  name: functionAppName
  location: location
  tags: tags
  kind: 'functionapp,linux'
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${userAssignedIdentityResourceId}': {}
    }
  }
  properties: {
    serverFarmId: plan.id
    virtualNetworkSubnetId: integrationSubnetId
    vnetRouteAllEnabled: true
    httpsOnly: true
    publicNetworkAccess: 'Disabled'
    keyVaultReferenceIdentity: userAssignedIdentityResourceId
    functionAppConfig: {
      deployment: {
        storage: {
          type: 'blobContainer'
          value: '${storageBlobEndpoint}${deploymentContainerName}'
          authentication: {
            type: 'UserAssignedIdentity'
            userAssignedIdentityResourceId: userAssignedIdentityResourceId
          }
        }
      }
      runtime: {
        name: 'powershell'
        version: powerShellVersion
      }
      scaleAndConcurrency: {
        instanceMemoryMB: instanceMemoryMB
        maximumInstanceCount: maximumInstanceCount
      }
    }
    siteConfig: {
      minTlsVersion: '1.2'
      ftpsState: 'Disabled'
      http20Enabled: true
      appSettings: [
        {
          name: 'AzureWebJobsStorage__blobServiceUri'
          value: storageBlobEndpoint
        }
        {
          name: 'AzureWebJobsStorage__queueServiceUri'
          value: replace(storageBlobEndpoint, '.blob.', '.queue.')
        }
        {
          name: 'AzureWebJobsStorage__tableServiceUri'
          value: replace(storageBlobEndpoint, '.blob.', '.table.')
        }
        {
          name: 'AzureWebJobsStorage__credential'
          value: 'managedidentity'
        }
        {
          name: 'AzureWebJobsStorage__clientId'
          value: userAssignedIdentityClientId
        }
        {
          name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
          value: appInsightsConnectionString
        }
        {
          name: 'APPLICATIONINSIGHTS_AUTHENTICATION_STRING'
          value: 'ClientId=${userAssignedIdentityClientId};Authorization=AAD'
        }
        {
          name: 'FUNCTIONS_WORKER_RUNTIME'
          value: 'powershell'
        }
        {
          name: 'UAMI_CLIENT_ID'
          value: userAssignedIdentityClientId
        }
        {
          name: 'STORAGE_ACCOUNT_NAME'
          value: storageAccountName
        }
        {
          name: 'STORAGE_BLOB_ENDPOINT'
          value: storageBlobEndpoint
        }
        {
          name: 'VMLIST_CONTAINER'
          value: configContainerName
        }
        {
          name: 'VMLIST_BLOB'
          value: vmListBlobName
        }
        {
          name: 'TARGET_SUBSCRIPTION_ID'
          value: subscriptionId
        }
        {
          name: 'TARGET_RESOURCE_GROUPS'
          value: targetRgList
        }
        {
          name: 'START_VMS_SCHEDULE'
          value: startVmsSchedule
        }
      ]
    }
  }
}

resource sitePrivateDnsZone 'Microsoft.Network/privateDnsZones@2024-06-01' = {
  name: 'privatelink.azurewebsites.net'
  location: 'global'
  tags: tags
}

resource siteDnsVnetLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = {
  parent: sitePrivateDnsZone
  name: 'link-${uniqueString(vnetId)}'
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: vnetId
    }
  }
}

resource sitePrivateEndpoint 'Microsoft.Network/privateEndpoints@2024-05-01' = {
  name: '${functionAppName}-pe'
  location: location
  tags: tags
  properties: {
    subnet: {
      id: privateEndpointSubnetId
    }
    privateLinkServiceConnections: [
      {
        name: 'sites'
        properties: {
          privateLinkServiceId: site.id
          groupIds: [
            'sites'
          ]
        }
      }
    ]
  }
}

resource sitePeDnsGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-05-01' = {
  parent: sitePrivateEndpoint
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'sites-config'
        properties: {
          privateDnsZoneId: sitePrivateDnsZone.id
        }
      }
    ]
  }
  dependsOn: [
    siteDnsVnetLink
  ]
}

output functionAppName string = site.name
output functionAppResourceId string = site.id
output functionAppPrincipalId string = userAssignedIdentityResourceId
