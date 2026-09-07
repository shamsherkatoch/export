using './main.bicep'

param workloadName = 'autostartvm'
param environment = 'dev'

param vnetAddressPrefix = '10.60.0.0/16'
param privateEndpointSubnetPrefix = '10.60.1.0/24'
param integrationSubnetPrefix = '10.60.2.0/24'

param instanceMemoryMB = 2048
param maximumInstanceCount = 100

param powerShellVersion = '7.4'

param startVmsSchedule = '0 0 7 * * 1-5'

param targetVmResourceGroupNames = [
  'rg-workloads-dev'
]

param tags = {
  workload: 'autostartvm'
  environment: 'dev'
  managedBy: 'bicep'
}
