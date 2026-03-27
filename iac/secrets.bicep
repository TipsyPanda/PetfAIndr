@description('The kube config for the target Kubernetes cluster.')
@secure()
param kubeConfig string

@description('Azure Storage Account name')
param storageAccountName string

@description('Azure Storage Account key')
@secure()
param storageAccountKey string

@description('Azure CosmosDB URL')
param cosmosUrl string

@description('Azure CosmosDB account key')
@secure()
param cosmosAccountKey string

@description('Service Bus Authorization Rule connection string')
@secure()
param serviceBusConnectionString string

@description('Custom Vision API training endpoint')
@secure()
param cvapiTrainingEndpoint string

@description('Custom Vision API training key')
@secure()
param cvapiTrainingKey string

@description('Custom Vision API prediction endpoint')
@secure()
param cvapiPredictionEndpoint string

@description('Custom Vision API prediction key')
@secure()
param cvapiPredictionKey string

@description('Custom Vision API prroject id')
@secure()
param cvapiProjectId string

@description('Custom Vision API prediction resource id')
@secure()
param cvapiPredictionResourceId string

extension kubernetes with {
  kubeConfig: kubeConfig
  namespace: 'default'
}

resource serviceBusSecret 'core/Secret@v1' = {
  metadata: {
    name: 'servicebus'
  }
  stringData: {
    connectionString: serviceBusConnectionString
  }
}

resource storageSecret 'core/Secret@v1' = {
  metadata: {
    name: 'storage'
  }
  stringData: {
    accountName: storageAccountName
    accountKey: storageAccountKey
  }
}

resource cosmosSecret 'core/Secret@v1' = {
  metadata: {
    name: 'cosmos'
  }
  stringData: {
    url: cosmosUrl
    masterKey: cosmosAccountKey
  }
}

resource cvapiSecret 'core/Secret@v1' = {
  metadata: {
    name: 'cvapi'
  }
  stringData: {
    trainingEndpoint: cvapiTrainingEndpoint
    trainingKey: cvapiTrainingKey
    predictionEndpoint: cvapiPredictionEndpoint
    predictionKey: cvapiPredictionKey
    projectId: cvapiProjectId
    predictionResourceId: cvapiPredictionResourceId
  }
}
