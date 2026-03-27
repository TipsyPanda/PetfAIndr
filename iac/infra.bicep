// Infrastructure Provisioning ------------------------------------------
// Provisions all Azure resources required by PetfAIndr.
// Run once (or when infrastructure needs updating) via infra.yml workflow.

@description('Azure region for all resources.')
param location string = 'swedencentral'

@description('Name of the Azure Container Registry.')
param registryName string = 'petfaindr6acr'

@description('Name of the AKS cluster.')
param clusterName string = 'petfaindraks'

@description('Name of the Azure Storage Account.')
param storageAccountName string = 'storepetfaindr'

@description('Name of the Azure Cosmos DB account.')
param cosmosAccountName string = 'cospetfaindr'

@description('Name of the Azure Service Bus namespace.')
param serviceBusNamespace string = 'buspetfaindr'

@description('Name of the Azure Cognitive Services account (Custom Vision).')
param cognitiveServicesName string = 'petspotraicustomvis1'

// -----------------------------------------------------------------------
// Azure Container Registry
// -----------------------------------------------------------------------
resource acr 'Microsoft.ContainerRegistry/registries@2023-11-01-preview' = {
  name: registryName
  location: location
  sku: {
    name: 'Basic'
  }
  properties: {
    adminUserEnabled: false
  }
}

// -----------------------------------------------------------------------
// Azure Kubernetes Service
// -----------------------------------------------------------------------
resource aks 'Microsoft.ContainerService/managedClusters@2024-08-01' = {
  name: clusterName
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    dnsPrefix: clusterName
    agentPoolProfiles: [
      {
        name: 'nodepool1'
        count: 2
        vmSize: 'Standard_B2s_v2'
        osType: 'Linux'
        mode: 'System'
      }
    ]
    ingressProfile: {
      webAppRouting: {
        enabled: true
      }
    }
    addonProfiles: {}
  }
}

// Grant AKS kubelet identity permission to pull images from ACR
resource acrPullRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(acr.id, aks.id, 'acrpull')
  scope: acr
  properties: {
    // AcrPull built-in role definition ID
    roleDefinitionId: subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions',
      '7f951dda-4ed3-4680-a7ca-43fe172d538d'
    )
    principalId: aks.properties.identityProfile.kubeletidentity.objectId
    principalType: 'ServicePrincipal'
  }
}

// -----------------------------------------------------------------------
// Azure Cosmos DB
// -----------------------------------------------------------------------
resource cosmosAccount 'Microsoft.DocumentDB/databaseAccounts@2022-08-15' = {
  name: cosmosAccountName
  location: location
  kind: 'GlobalDocumentDB'
  properties: {
    databaseAccountOfferType: 'Standard'
    locations: [
      {
        locationName: location
        failoverPriority: 0
      }
    ]
    consistencyPolicy: {
      defaultConsistencyLevel: 'Session'
    }
  }
}

resource cosmosDatabase 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases@2022-08-15' = {
  parent: cosmosAccount
  name: 'petfaindr'
  properties: {
    resource: {
      id: 'petfaindr'
    }
  }
}

resource cosmosContainer 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers@2022-08-15' = {
  parent: cosmosDatabase
  name: 'pets'
  properties: {
    resource: {
      id: 'pets'
      partitionKey: {
        paths: ['/id']
        kind: 'Hash'
      }
    }
  }
}

// -----------------------------------------------------------------------
// Azure Service Bus
// -----------------------------------------------------------------------
resource serviceBusNamespaceResource 'Microsoft.ServiceBus/namespaces@2022-01-01-preview' = {
  name: serviceBusNamespace
  location: location
  sku: {
    name: 'Standard'
  }
}

resource serviceBusAuthRule 'Microsoft.ServiceBus/namespaces/AuthorizationRules@2022-01-01-preview' = {
  parent: serviceBusNamespaceResource
  name: 'Dapr'
  properties: {
    rights: [
      'Listen'
      'Send'
      'Manage'
    ]
  }
}

// -----------------------------------------------------------------------
// Azure Storage Account
// -----------------------------------------------------------------------
resource storageAccount 'Microsoft.Storage/storageAccounts@2022-05-01' = {
  name: storageAccountName
  location: location
  kind: 'StorageV2'
  sku: {
    name: 'Standard_LRS'
  }
}

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2022-05-01' = {
  parent: storageAccount
  name: 'default'
}

resource imagesContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2022-05-01' = {
  parent: blobService
  name: 'images'
  properties: {
    publicAccess: 'None'
  }
}

// -----------------------------------------------------------------------
// Azure Cognitive Services (Custom Vision)
// -----------------------------------------------------------------------
resource customVision 'Microsoft.CognitiveServices/accounts@2023-05-01' = {
  name: cognitiveServicesName
  location: location
  kind: 'CognitiveServices'
  sku: {
    name: 'S0'
  }
  properties: {
    publicNetworkAccess: 'Enabled'
  }
}

// -----------------------------------------------------------------------
// Outputs
// -----------------------------------------------------------------------
output acrLoginServer string = acr.properties.loginServer
output aksClusterName string = aks.name
output webAppRoutingEnabled bool = aks.properties.ingressProfile.webAppRouting.enabled
output cognitiveServicesEndpoint string = customVision.properties.endpoint
