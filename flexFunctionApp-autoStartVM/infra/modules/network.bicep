param location string
param tags object
param vnetName string
param vnetAddressPrefix string
param privateEndpointSubnetPrefix string
param integrationSubnetPrefix string

var privateEndpointSubnetName = 'snet-pe'
var integrationSubnetName = 'snet-integration'

resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: vnetName
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [
        vnetAddressPrefix
      ]
    }
    subnets: [
      {
        name: privateEndpointSubnetName
        properties: {
          addressPrefixes: [
            privateEndpointSubnetPrefix
          ]
          privateEndpointNetworkPolicies: 'Disabled'
        }
      }
      {
        name: integrationSubnetName
        properties: {
          addressPrefixes: [
            integrationSubnetPrefix
          ]
          delegations: [
            {
              name: 'delegation-app-environments'
              properties: {
                serviceName: 'Microsoft.App/environments'
              }
            }
          ]
          serviceEndpoints: [
            {
              service: 'Microsoft.Storage'
            }
          ]
        }
      }
    ]
  }
}

output vnetId string = vnet.id
output privateEndpointSubnetId string = filter(vnet.properties.subnets, s => s.name == privateEndpointSubnetName)[0].id
output integrationSubnetId string = filter(vnet.properties.subnets, s => s.name == integrationSubnetName)[0].id
