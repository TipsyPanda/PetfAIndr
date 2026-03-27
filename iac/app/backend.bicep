@description('The kube config for the target Kubernetes cluster.')
@secure()
param kubeConfig string

@description('Address of the container registry where container resides')
param containerRegistry string

@description('Tag of container to use')
param containerTag string = '1'

extension kubernetes with {
  kubeConfig: kubeConfig
  namespace: 'default'
} as k8s

resource backendDeployment 'apps/Deployment@v1' = {
  metadata: {
    name: 'backend'
    labels: {
      app: 'backend'
    }
  }
  spec: {
    replicas: 1
    selector: {
      matchLabels: {
        app: 'backend'
      }
    }
    template: {
      metadata: {
        labels: {
          app: 'backend'
        }
        annotations: {
          'dapr.io/enabled': 'true'
          'dapr.io/app-id': 'backend'
          'dapr.io/app-port': '5000'
        }
      }
      spec: {
        containers: [
          {
            name: 'backend'
            image: '${containerRegistry}/petb:${containerTag}'
            imagePullPolicy: 'Always'
            env: [
              {
                name: 'SERVICEBUS_CONNECTIONSTRING'
                valueFrom: {
                  secretKeyRef: {
                    name: 'servicebus'
                    key: 'connectionString'
                  }
                }
              }, {
                name: 'STORAGE_ACCOUNT_NAME'
                valueFrom: {
                  secretKeyRef: {
                    name: 'storage'
                    key: 'accountName'
                  }
                }
              }, {
                name: 'CVAPI_TRAINING_ENDPOINT'
                valueFrom: {
                  secretKeyRef: {
                    name: 'cvapi'
                    key: 'trainingEndpoint'
                  }
                }
              }, {
                name: 'CVAPI_TRAINING_KEY'
                valueFrom: {
                  secretKeyRef: {
                    name: 'cvapi'
                    key: 'trainingKey'
                  }
                }
              }, {
                name: 'CVAPI_PREDICTION_ENDPOINT'
                valueFrom: {
                  secretKeyRef: {
                    name: 'cvapi'
                    key: 'predictionEndpoint'
                  }
                }
              }, {
                name: 'CVAPI_PREDICTION_KEY'
                valueFrom: {
                  secretKeyRef: {
                    name: 'cvapi'
                    key: 'predictionKey'
                  }
                }
              }, {
                name: 'CVAPI_PROJECT_ID'
                valueFrom: {
                  secretKeyRef: {
                    name: 'cvapi'
                    key: 'projectId'
                  }
                }
              }, {
                name: 'CVAPI_PREDICTION_RESOURCE_ID'
                valueFrom: {
                  secretKeyRef: {
                    name: 'cvapi'
                    key: 'predictionResourceId'
                  }
                }
              }
            ]
          }
        ]
      }//end of spec
    }
  }
}
