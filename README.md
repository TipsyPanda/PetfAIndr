# PetfAIndr

A cloud-native pet identification app built with Dapr, running on Azure Kubernetes Service.

## Architecture

- **Frontend** — ASP.NET Core web app
- **Backend** — Python Flask API
- **Dapr** — service mesh for state (Cosmos DB), pub/sub (Service Bus), and blob storage
- **Custom Vision** — pet image classification

## CI/CD Pipelines

| Workflow | Trigger | What it does |
|---|---|---|
| `infra.yml` | Push to `iac/infra.bicep` or manual | Registers providers, creates resource group, deploys all Azure resources |
| `build-push.yml` | Push to `container-images/` or manual | Builds backend + frontend images, pushes to ACR |
| `deploy.yml` | After successful build-push or manual | Deploys secrets, Dapr components, and workloads to AKS |

## One-Time Azure Setup

### 1. Create the resource group

```powershell
az group create --name petfaindr-rg --location swedencentral
```

### 2. Create the managed identity for GitHub Actions

```powershell
az identity create --name petfaindr-github-id --resource-group petfaindr-rg --location swedencentral
```

### 3. Add federated credential for GitHub Actions OIDC

```powershell
az identity federated-credential create --identity-name petfaindr-github-id --resource-group petfaindr-rg --name github-actions-main --issuer https://token.actions.githubusercontent.com --subject repo:TipsyPanda/PetfAIndr:ref:refs/heads/main --audiences api://AzureADTokenExchange
```

### 4. Assign roles to the managed identity (subscription-level)

```powershell
$PRINCIPAL_ID = (az identity show --name petfaindr-github-id --resource-group petfaindr-rg --query principalId -o tsv)
$SCOPE = "/subscriptions/" + (az account show --query id -o tsv)

az role assignment create --assignee-object-id $PRINCIPAL_ID --assignee-principal-type ServicePrincipal --role "Contributor" --scope $SCOPE
az role assignment create --assignee-object-id $PRINCIPAL_ID --assignee-principal-type ServicePrincipal --role "User Access Administrator" --scope $SCOPE
```

### 5. Configure GitHub Secrets

Set these secrets in the repository (`Settings > Secrets and variables > Actions`):

| Secret | How to get the value |
|---|---|
| `AZURE_CLIENT_ID` | `az identity show --name petfaindr-github-id --resource-group petfaindr-rg --query clientId -o tsv` |
| `AZURE_TENANT_ID` | `az account show --query tenantId -o tsv` |
| `AZURE_SUBSCRIPTION_ID` | `az account show --query id -o tsv` |

### 6. Provision infrastructure

Run the `infra.yml` workflow (push a change to `iac/infra.bicep` or trigger manually). This automatically registers all required resource providers and deploys:

- Azure Container Registry (`petfaindr6acr`)
- AKS cluster (`petfaindraks`) with Dapr extension and web app routing
- Cosmos DB (`petfaindr` database, `pets` container)
- Service Bus namespace (`buspetfaindr`)
- Storage account (`storepetfaindr`, `images` blob container)
- Cognitive Services / Custom Vision (`petspotraicustomvis1`)

### 7. Create Custom Vision project (manual, one-time)

1. Go to [customvision.ai](https://www.customvision.ai) and sign in
2. Create a new Classification project using the `petspotraicustomvis1` resource
3. Copy the Project ID from Project Settings
4. Add it as GitHub secret `CVAPI_PROJECT_ID`

### 8. Build, push, and deploy

Trigger the `build-push.yml` workflow (push a change to `container-images/` or trigger manually). Once it succeeds, `deploy.yml` runs automatically and deploys everything to AKS.
