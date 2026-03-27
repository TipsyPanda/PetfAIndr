@description('The kube config for the target Kubernetes cluster.')
@secure()
param kubeConfig string

extension kubernetes with {
  kubeConfig: kubeConfig
  namespace: 'default'
}

resource ingress 'networking.k8s.io/Ingress@v1' = {
  metadata: {
    name: 'frontend'
    annotations: {
      'spec.ingressClassName': 'webapprouting.kubernetes.azure.com'
    }
  }
  spec: {
    ingressClassName: 'webapprouting.kubernetes.azure.com'
    rules: [
      {
        http: {
          paths: [
            {
              path: '/'
              pathType: 'Prefix'
              backend: {
                service: {
                  name: 'frontend'
                  port: {
                    number: 80
                  }
                }
              }
            }
          ]
        }
      }
    ]
  }
}
