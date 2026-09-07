param location string
param tags object
param identityName string

resource uami 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: identityName
  location: location
  tags: tags
}

output identityResourceId string = uami.id
output identityPrincipalId string = uami.properties.principalId
output identityClientId string = uami.properties.clientId
