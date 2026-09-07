targetScope = 'resourceGroup'

param userAssignedIdentityPrincipalId string
param storageAccountName string
param targetVmResourceGroupNames array

var storageBlobDataOwnerRoleId = 'b7e6dc6d-f1e8-4753-8033-0f276bb0955b'
var storageBlobDataContributorRoleId = 'ba92f5b4-2d11-453d-a403-e96b0029c9fe'
var storageQueueDataContributorRoleId = '974c5e8b-45b9-4653-ba55-5f855dd0fb88'
var storageTableDataContributorRoleId = '0a9a7e1f-b9d0-4cc4-a60d-0319b160aaa3'
var vmContributorRoleId = '9980e02c-c2be-4d73-94e8-173b1dc7cf3c'

resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' existing = {
  name: storageAccountName
}

resource storageBlobDataOwner 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: storage
  name: guid(storage.id, userAssignedIdentityPrincipalId, storageBlobDataOwnerRoleId)
  properties: {
    principalId: userAssignedIdentityPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageBlobDataOwnerRoleId)
  }
}

resource storageBlobDataContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: storage
  name: guid(storage.id, userAssignedIdentityPrincipalId, storageBlobDataContributorRoleId)
  properties: {
    principalId: userAssignedIdentityPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageBlobDataContributorRoleId)
  }
}

resource storageQueueDataContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: storage
  name: guid(storage.id, userAssignedIdentityPrincipalId, storageQueueDataContributorRoleId)
  properties: {
    principalId: userAssignedIdentityPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageQueueDataContributorRoleId)
  }
}

resource storageTableDataContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: storage
  name: guid(storage.id, userAssignedIdentityPrincipalId, storageTableDataContributorRoleId)
  properties: {
    principalId: userAssignedIdentityPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageTableDataContributorRoleId)
  }
}

module vmRoleAssignments 'vmRoleAssignment.bicep' = [for rgName in targetVmResourceGroupNames: {
  name: 'vmRole-${uniqueString(rgName, userAssignedIdentityPrincipalId)}'
  scope: resourceGroup(rgName)
  params: {
    principalId: userAssignedIdentityPrincipalId
    roleDefinitionId: vmContributorRoleId
  }
}]
