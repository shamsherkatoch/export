targetScope = 'resourceGroup'

@description('Short workload name used to build resource names.')
@minLength(2)
@maxLength(12)
param workloadName string = 'autostartvm'

@description('Environment suffix, e.g. dev / tst / prd.')
@allowed([
  'dev'
  'tst'
  'prd'
])
param environment string = 'dev'

@description('Deployment region.')
param location string = resourceGroup().location

@description('Address space for the VNet.')
param vnetAddressPrefix string = '10.60.0.0/16'

@description('Subnet reserved for Private Endpoints.')
param privateEndpointSubnetPrefix string = '10.60.1.0/24'

@description('Subnet delegated to the Function App for VNet integration.')
param integrationSubnetPrefix string = '10.60.2.0/24'

@description('Flex Consumption instance memory (MB). Allowed: 512, 2048, 4096.')
@allowed([
  512
  2048
  4096
])
param instanceMemoryMB int = 2048

@description('Maximum instance count for Flex Consumption.')
@minValue(40)
@maxValue(1000)
param maximumInstanceCount int = 100

@description('PowerShell runtime version for the Function App.')
@allowed([
  '7.4'
])
param powerShellVersion string = '7.4'

@description('Resource groups the Function App identity is allowed to start VMs in. Defaults to the deployment resource group.')
param targetVmResourceGroupNames array = [
  resourceGroup().name
]

@description('Timer trigger CRON expression (NCRONTAB, 6 fields). Default: 07:00 weekdays UTC.')
param startVmsSchedule string = '0 0 7 * * 1-5'

@description('Tags applied to every resource.')
param tags object = {
  workload: workloadName
  environment: environment
  managedBy: 'bicep'
}

var namePrefix = toLower('${workloadName}-${environment}')
var storageAccountName = toLower(replace('st${workloadName}${environment}${uniqueString(resourceGroup().id)}', '-', ''))
var deploymentContainerName = 'app-package'
var configContainerName = 'config'
var vmListBlobName = 'vmList.json'

module network 'modules/network.bicep' = {
  name: 'network'
  params: {
    location: location
    tags: tags
    vnetName: '${namePrefix}-vnet'
    vnetAddressPrefix: vnetAddressPrefix
    privateEndpointSubnetPrefix: privateEndpointSubnetPrefix
    integrationSubnetPrefix: integrationSubnetPrefix
  }
}

module identity 'modules/identity.bicep' = {
  name: 'identity'
  params: {
    location: location
    tags: tags
    identityName: '${namePrefix}-uami'
  }
}

module monitoring 'modules/monitoring.bicep' = {
  name: 'monitoring'
  params: {
    location: location
    tags: tags
    logAnalyticsName: '${namePrefix}-law'
    appInsightsName: '${namePrefix}-appi'
  }
}

module storage 'modules/storage.bicep' = {
  name: 'storage'
  params: {
    location: location
    tags: tags
    storageAccountName: storageAccountName
    deploymentContainerName: deploymentContainerName
    configContainerName: configContainerName
    privateEndpointSubnetId: network.outputs.privateEndpointSubnetId
    vnetId: network.outputs.vnetId
  }
}

module functionApp 'modules/functionApp.bicep' = {
  name: 'functionApp'
  params: {
    location: location
    tags: tags
    planName: '${namePrefix}-plan'
    functionAppName: '${namePrefix}-func'
    integrationSubnetId: network.outputs.integrationSubnetId
    privateEndpointSubnetId: network.outputs.privateEndpointSubnetId
    vnetId: network.outputs.vnetId
    userAssignedIdentityResourceId: identity.outputs.identityResourceId
    userAssignedIdentityClientId: identity.outputs.identityClientId
    storageAccountName: storage.outputs.storageAccountName
    storageBlobEndpoint: storage.outputs.blobEndpoint
    deploymentContainerName: deploymentContainerName
    configContainerName: configContainerName
    vmListBlobName: vmListBlobName
    appInsightsConnectionString: monitoring.outputs.appInsightsConnectionString
    instanceMemoryMB: instanceMemoryMB
    maximumInstanceCount: maximumInstanceCount
    powerShellVersion: powerShellVersion
    startVmsSchedule: startVmsSchedule
    targetVmResourceGroupNames: targetVmResourceGroupNames
  }
}

module rbac 'modules/roleAssignments.bicep' = {
  name: 'rbac'
  params: {
    userAssignedIdentityPrincipalId: identity.outputs.identityPrincipalId
    storageAccountName: storage.outputs.storageAccountName
    targetVmResourceGroupNames: targetVmResourceGroupNames
  }
}

output functionAppName string = functionApp.outputs.functionAppName
output functionAppResourceId string = functionApp.outputs.functionAppResourceId
output storageAccountName string = storage.outputs.storageAccountName
output deploymentContainerName string = deploymentContainerName
output configContainerName string = configContainerName
output vmListBlobName string = vmListBlobName
output userAssignedIdentityClientId string = identity.outputs.identityClientId
output userAssignedIdentityResourceId string = identity.outputs.identityResourceId
