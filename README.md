# PetfAIndr

## Prerequisites

- Azure CLI (`az`) installed and logged in
- A GitHub repository at `TipsyPanda/PetfAIndr`

## One-Time Azure Setup

### 1. Create the resource group

```powershell
az group create --name petfaindr-rg --location swedencentral
```

### 2. Register required resource providers

```powershell
az provider register --namespace Microsoft.ContainerService
az provider register --namespace Microsoft.ContainerRegistry
```

Wait until both show `Registered`:

```powershell
az provider show --namespace Microsoft.ContainerService --query registrationState -o tsv
az provider show --namespace Microsoft.ContainerRegistry --query registrationState -o tsv
```

### 3. Create the managed identity for GitHub Actions

```powershell
az identity create --name petfaindr-github-id --resource-group petfaindr-rg --location swedencentral
```

### 4. Add federated credential for GitHub Actions OIDC

```powershell
az identity federated-credential create --identity-name petfaindr-github-id --resource-group petfaindr-rg --name github-actions-main --issuer https://token.actions.githubusercontent.com --subject repo:TipsyPanda/PetfAIndr:ref:refs/heads/main --audiences api://AzureADTokenExchange
```

### 5. Assign roles to the managed identity

```powershell
$PRINCIPAL_ID = (az identity show --name petfaindr-github-id --resource-group petfaindr-rg --query principalId -o tsv)
$SCOPE = "/subscriptions/<your-subscription-id>/resourceGroups/petfaindr-rg"

# Contributor - create/manage resources
az role assignment create --assignee-object-id $PRINCIPAL_ID --assignee-principal-type ServicePrincipal --role "Contributor" --scope $SCOPE

# User Access Administrator - create role assignments (e.g. AKS -> ACR pull)
az role assignment create --assignee-object-id $PRINCIPAL_ID --assignee-principal-type ServicePrincipal --role "User Access Administrator" --scope $SCOPE
```

### 6. Configure GitHub Secrets

Set these secrets in the repository (`Settings > Secrets and variables > Actions`):

| Secret | How to get the value |
|---|---|
| `AZURE_CLIENT_ID` | `az identity show --name petfaindr-github-id --resource-group petfaindr-rg --query clientId -o tsv` |
| `AZURE_TENANT_ID` | `az account show --query tenantId -o tsv` |
| `AZURE_SUBSCRIPTION_ID` | `az account show --query id -o tsv` |
