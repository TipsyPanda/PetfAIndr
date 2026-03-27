@description('Name of the AKS cluster. Defaults to a unique hash prefixed with "petfaindr"')
param clusterName string = 'petfaindraks'

@description('Azure Storage Account name')
param storageAccountName string = 'storepetfaindr'

@description('Azure CosmosDB account name')
param cosmosAccountName string = 'cospetfaindr'

@description('Azure Service Bus authorization rule name')
param serviceBusAuthorizationRuleName string = 'buspetfaindr/Dapr'

resource aksCluster 'Microsoft.ContainerService/managedClusters@2024-08-01' existing = {
  name: clusterName
}

resource cosmosAccount 'Microsoft.DocumentDB/databaseAccounts@2022-08-15' existing = {
  name: cosmosAccountName
}

resource storageAccount 'Microsoft.Storage/storageAccounts@2022-05-01' existing = {
  name: storageAccountName
}

resource serviceBusAuthorizationRule 'Microsoft.ServiceBus/namespaces/AuthorizationRules@2022-01-01-preview' existing = {
  name: serviceBusAuthorizationRuleName
}

module secrets 'secrets.bicep' = {
  name: 'secrets'
  params: {
    cosmosUrl: cosmosAccount.properties.documentEndpoint
    cosmosAccountKey: cosmosAccount.listKeys().primaryMasterKey
    kubeConfig: aksCluster.listClusterAdminCredential().kubeconfigs[0].value
    storageAccountName: storageAccount.name
    storageAccountKey: storageAccount.listKeys().keys[0].value
    serviceBusConnectionString: serviceBusAuthorizationRule.listKeys().primaryConnectionString
    cvapiTrainingEndpoint: 'https://swedencentral.api.cognitive.microsoft.com/'
    cvapiTrainingKey: 'fcff64a674a34493b765103997e16376'
    cvapiPredictionEndpoint: 'https://swedencentral.api.cognitive.microsoft.com/'
    cvapiPredictionKey: '8cd6b878a0a94adf8087b31cb627eec0'
    cvapiProjectId: 'f219fa6d-9006-4595-94d7-804f896e5a9b'
    cvapiPredictionResourceId: '/subscriptions/52d55cac-3b07-467e-969f-073f0a07b78e/resourceGroups/RG-PetFaindr/providers/Microsoft.CognitiveServices/accounts/petspotraicustomvis1'
  }
}
