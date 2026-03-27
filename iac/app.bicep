// Application -----------------------------------------

@description('Name of the container registry. Defaults to unique hashed ID prefixed with "petfaindr"')
param registryName string = 'petfaindr6acr'

@description('Name of the AKS cluster. Defaults to a unique hash prefixed with "petfaindr"')
param clusterName string = 'petfaindraks'

@description('Tag of the container images to deploy. Defaults to "1" for local use.')
param containerTag string = '1'

resource containerRegistry 'Microsoft.ContainerRegistry/registries@2023-11-01-preview' existing = {
  name: registryName
}

resource aksCluster 'Microsoft.ContainerService/managedClusters@2024-08-01' existing = {
  name: clusterName
}

module frontend 'app/frontend.bicep' = {
  name: 'frontend'
  params: {
    containerRegistry: containerRegistry.properties.loginServer
    kubeConfig: aksCluster.listClusterAdminCredential().kubeconfigs[0].value
    containerTag: containerTag
  }
}

module backend 'app/backend.bicep' = {
  name: 'backend'
  params: {
    containerRegistry: containerRegistry.properties.loginServer
    kubeConfig: aksCluster.listClusterAdminCredential().kubeconfigs[0].value
    containerTag: containerTag
  }
}

module ingress 'app/ingress.bicep' = {
  name: 'ingress'
  params: {
    HTTPApplicationRoutingZoneName: aksCluster.properties.addonProfiles.httpApplicationRouting.config.HTTPApplicationRoutingZoneName
    kubeConfig: aksCluster.listClusterAdminCredential().kubeconfigs[0].value
  }
}
