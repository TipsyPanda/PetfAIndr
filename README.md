# PetfAIndr

A cloud-native pet identification app built with Dapr, running on Azure Kubernetes Service.

## How it works (30-second mental model)

A user opens a website and submits either a "my pet is lost" form (with photos) or a "I found this pet" form (with a single photo). The system trains a per-pet image-classification model from lost-pet photos, and runs new found-pet photos against that model. When a found photo matches a tagged lost pet with ≥70% confidence, that pet's record flips from `lost` → `found`. The user sees the change on the Status page.

The trick is that all this work is split across two containers (frontend + backend) that don't call each other directly. They communicate via Azure Service Bus, share state via Cosmos DB, and share images via Blob Storage — all mediated by a sidecar called **Dapr** so the application code never speaks any Azure SDK.

## Architecture

### Azure resources, and what each one does

Provisioned in [iac/infra.bicep](iac/infra.bicep):

| Resource | Role | Why it's here |
|---|---|---|
| **AKS cluster** `petfaindraks` | Runs the frontend + backend pods | Kubernetes is the runtime; Dapr installs as an AKS extension on top |
| **ACR** `petfaindr6acr` | Stores container images (`petf:tag`, `petb:tag`) | AKS pulls from here. AcrPull role is granted to the AKS kubelet identity in Bicep |
| **Cosmos DB** `cospetfaindr` → DB `petfaindr` → container `pets` | Source of truth for pet records | Used as a Dapr **state store** — Dapr writes one document per pet, partition-keyed by `/id` |
| **Service Bus** `buspetfaindr` | Async messaging | Used as the Dapr **pubsub broker** — two topics, `lostPet` and `foundPet` |
| **Storage account** `storepetfaindr` → container `images` | Holds uploaded pet photos | Frontend writes via a Dapr **output binding**; Custom Vision reads the URLs directly |
| **Custom Vision** (manually created — Bicep currently misprovisions this as a generic CognitiveServices account, see CHANGELOG known issues) | Trains and serves the per-pet image classifier | The actual ML brain |

### The two containers running in AKS

Each pod has **two containers**:

- The app container (frontend or backend)
- The **Dapr sidecar** (`daprd`), injected automatically because the pod has annotations `dapr.io/enabled: 'true'` and `dapr.io/app-id: 'frontend'|'backend'`

Inside a pod they share localhost. The app speaks plain HTTP/gRPC to the sidecar on a fixed local port; the sidecar speaks Azure to the actual cloud services. This is why the application code never imports `azure-servicebus`, `azure-cosmos`, or `azure-storage-blob` — only the sidecar does.

### Network ingress — how a browser reaches the frontend

Two paths exist in this codebase, only one is wired up right now:

1. **`frontend-svc` Service of type `LoadBalancer`** — defined in [iac/app/frontend.bicep](iac/app/frontend.bicep). Kubernetes asks Azure to provision a public IP + Azure Load Balancer rule (port 80 → pod port 80). The user's browser hits that public IP, the LB forwards to whichever pod is healthy. This is the active path.
2. **Web App Routing ingress** — [iac/app/ingress.bicep](iac/app/ingress.bicep) defines an Ingress object using the AKS-managed ingress controller (enabled by `ingressProfile.webAppRouting.enabled = true` on the cluster). Currently commented out in [iac/app.bicep](iac/app.bicep). Would give a hostname-based router (and TLS) instead of raw IP.

Public IP for path 1: `kubectl get svc frontend-svc -o wide` shows the EXTERNAL-IP column.

### Lost-pet flow (end-to-end)

```
Browser                Frontend pod              Service Bus     Backend pod              Custom Vision     Cosmos DB
   │                   ┌──app──┬─dapr─┐               │           ┌─dapr─┬──app──┐              │              │
   │ submit form       │       │      │               │           │      │       │              │              │
   ├──────────────────▶│ POST  │      │               │           │      │       │              │              │
   │ (multipart)       │ /Lost │      │               │           │      │       │              │              │
   │                   │       │      │               │           │      │       │              │              │
   │  ① upload images  │   ───▶│ blob │               │           │      │       │              │              │
   │     (per file)    │       │ bind │  PUT image───────────────────────────────────▶ Storage account
   │                   │       │      │               │           │      │       │              │              │
   │  ② save pet state │   ───▶│state │  upsert doc───────────────────────────────────────────▶│
   │                   │       │ store│  (key=guid)   │           │      │       │              │              │
   │                   │       │      │               │           │      │       │              │              │
   │  ③ publish event  │   ───▶│pubsub│  publish─────▶│           │      │       │              │              │
   │                   │       │      │  topic=lostPet│  deliver─▶│      │       │              │              │
   │                   │       │      │               │           │ POST /lostPet │              │              │
   │                   │       │      │               │           │      │       │              │              │
   │  redirect /submit │       │      │               │           │      │ ack 200│              │              │
   │◀──────────────────│       │      │               │           │      │ (queue threadpool)    │              │
                                                                                  │              │              │
                                                                                  │ get state ──▶│              │
                                                                                  │ (pet doc)    │              │
                                                                                  │              │              │
                                                                                  │ POST /tags  ─────────────▶
                                                                                  │ POST /images/urls (xN) ──▶
                                                                                  │ POST /train ─────────────▶
                                                                                  │ poll /iterations/{id} ──▶
                                                                                  │ POST /publish?publishName=publishediteration
                                                                                  │ save_state(published_db_iteration_id) ▶
```

Step by step:

1. **Form submit** — `LostPet.razor` `HandleSubmit` runs server-side (Blazor Server). It gets a `DaprClient`, then for each selected image calls `daprClient.InvokeBindingAsync("images", "create", bytes, metadata)`. The frontend's Dapr sidecar takes that, looks up the `images` component in [iac/dapr/images.yaml](iac/dapr/images.yaml) (a `bindings.azure.blobstorage` component, with creds pulled from the `storage` Kubernetes secret), and PUTs the bytes into the `images` container in the storage account. Filename is a fresh GUID + the original extension.
2. **Save pet state** — `petModel.SavePetStateAsync(daprClient, "pets")` in [PetModel.cs](container-images/frontend/petfaindr/Data/PetModel.cs) → `daprClient.SaveStateAsync("pets", id, this)`. Sidecar consults the `pets` Dapr component ([iac/dapr/pets.yaml](iac/dapr/pets.yaml), type `state.azure.cosmosdb`) and upserts a JSON document into Cosmos. Document `id` = the GUID generated in `PetModel`.
3. **Publish event** — `petModel.PublishLostPetAsync` does `daprClient.PublishEventAsync("pubsub", "lostPet", { petId: ID })`. Sidecar consults [iac/dapr/pubsub.yaml](iac/dapr/pubsub.yaml) (`pubsub.azure.servicebus`) and publishes a CloudEvent envelope onto the `lostPet` Service Bus topic. Frontend immediately redirects the user to `/submit`.
4. **Service Bus delivery** — Service Bus has a subscription auto-created by Dapr (with subscription name = the consumer's app-id, here `backend`). The backend pod's Dapr sidecar receives the message and POSTs it to `http://localhost:5000/lostPet` (the `app-port` from the pod annotation). The route map comes from `app.py`'s `/dapr/subscribe` endpoint — Dapr scrapes that at sidecar startup to learn what topics this app wants.
5. **Backend acknowledges fast, processes async** — the route handler immediately returns 200 and submits `process_lost_pet(event)` to the thread pool. This is critical — Dapr/Service Bus considers the message delivered as soon as it gets the 200, so we don't block the broker for the 1–2 minutes of training.
6. **Backend retrieves the pet doc** — `dapr.get_state("pets", id)` reads back the document the frontend wrote, via Cosmos.
7. **Custom Vision training**:
   - `POST /tags?name={petId}` creates a tag — **the tag name *is* the Cosmos document id**, the design trick that lets the predict step know which DB record to flip.
   - `POST /images/urls` per image hands Custom Vision the public blob URL. (This is why blob public access is currently enabled.)
   - 30-second sleep so Custom Vision finishes indexing the new images.
   - Now under a `threading.Lock`: `POST /train?forceTrain=true` returns an `iteration_id`. The lock serializes this across concurrent submissions because Custom Vision permits only one active training per project.
   - `wait_for_training_completion(iteration_id)` polls `GET /iterations/{id}` every 10s until `status == 'Completed'`.
   - Unpublish whatever was previously published under the name `publishediteration` (Cosmos key `published_db_iteration_id` tracks it), then `POST /iterations/{id}/publish?publishName=publishediteration&predictionId=...` to publish the new one.
   - Save the new iteration ID back to Cosmos.

The model is now live and queryable.

### Found-pet flow (end-to-end)

Same shape, much shorter:

```
Browser ──▶ Frontend ──▶ blob (image upload via Dapr binding)
                  └──▶ pubsub topic=foundPet ──▶ Backend /foundPet
                                                       │
                                                       ▼
                                          POST /Prediction/{project}/classify/iterations/publishediteration/url
                                                       │  body = { url: blob URL of just-uploaded photo }
                                                       ▼
                                              for each prediction with prob > 0.7:
                                                  - tagName *is* the Cosmos id of a lost pet
                                                  - dapr.get_state("pets", tagName)
                                                  - state['state'] = 'found'
                                                  - dapr.save_state("pets", tagName, ...)
```

Key design choice: because each lost pet's tag is named with its Cosmos `id`, the prediction response gives the backend exactly the key it needs to look up and mutate the right document. No separate "tag-to-pet" lookup table is required.

### Status page — how the user sees the result

`Status.razor` (and `Lost.razor` / `Found.razor`) call `PetModel.GetPetStateAsync` → `daprClient.QueryStateAsync<PetModel>("pets", "SELECT * FROM c")`. Dapr issues that as a Cosmos SQL query and streams documents back. Each row's `state` field is what changed in step 7 of the lost-pet flow, so the Status page reflects matches in real time (refresh-driven, no SignalR).

### Secrets — how the apps get credentials without ever seeing them

[iac/secrets.bicep](iac/secrets.bicep) creates Kubernetes Secrets (`servicebus`, `storage`, `cosmos`, `cvapi`) with the connection strings/keys. Two consumption paths:

- **Dapr components** reference them via `secretKeyRef` — see [iac/dapr/pubsub.yaml](iac/dapr/pubsub.yaml), [iac/dapr/pets.yaml](iac/dapr/pets.yaml), [iac/dapr/images.yaml](iac/dapr/images.yaml). The Dapr control plane resolves these at component-load time so the connection strings never reach the app.
- **Backend pod** mounts the `cvapi` and `storage` secrets as env vars in [iac/app/backend.bicep](iac/app/backend.bicep), because the backend talks to Custom Vision directly (Dapr has no Custom Vision component).

### Why Dapr at all

Without Dapr, the frontend would have `Azure.Storage.Blobs` + `Azure.Messaging.ServiceBus` + `Microsoft.Azure.Cosmos` SDKs, three connection strings, and three retry/back-off implementations. The app code becomes Azure-shaped. Dapr replaces all of that with a uniform `daprClient.InvokeBindingAsync` / `PublishEventAsync` / `SaveStateAsync` API speaking to a sidecar over localhost. Swap Service Bus for Kafka by changing one yaml file, no app rebuild. That's the core selling point of this stack.

### Putting it all together — the request that actually pages someone

A typical "found my dog!" lifecycle, with the components touched on each line:

1. Owner submits Lost form → **Storage** (5 photos) + **Cosmos** (pet doc) + **Service Bus** (`lostPet` event)
2. Backend trains → **Custom Vision** (tag, images, train, poll, publish)
3. Stranger submits Found form → **Storage** (1 photo) + **Service Bus** (`foundPet` event)
4. Backend predicts → **Custom Vision** (classify URL → predictions list)
5. Match above 0.7 → **Cosmos** (pet doc `state` field flips to `found`)
6. Owner refreshes Status page → **Cosmos** (query) → render

Every arrow between containers and Azure services is mediated by Dapr; only the Custom Vision call is a direct HTTPS call from app code, because there's no Dapr component for it.

## How this solution was built

The solution did not arrive complete from the assignment baseline. It was assembled in three phases.

### Phase 1 — Azure resource provisioning + CI/CD (pre-baseline)

The original assignment template provided application code, Dapr component YAMLs, and Bicep modules that *deploy app code* — but it referenced every Azure resource as `existing`, with no IaC that actually creates them. There were also no GitHub workflows. The first phase of work added:

- **`iac/infra.bicep`** written from scratch — provisions AKS (with the Dapr extension and Web App Routing), ACR, Cosmos DB account / database / `pets` container, Service Bus namespace + Dapr auth rule, Storage account + `images` container, Cognitive Services account, and the `AcrPull` role assignment so AKS can pull images.
- **`.github/workflows/`** — three pipelines:
  - [`infra.yml`](.github/workflows/infra.yml) runs `infra.bicep`
  - [`build-push.yml`](.github/workflows/build-push.yml) builds + pushes frontend/backend images to ACR
  - [`deploy.yml`](.github/workflows/deploy.yml) runs `secrets.bicep` (filling in real values from GitHub secrets, replacing the placeholder strings the baseline shipped with) then `app.bicep`
- Iterative networking fixes (`update app routing`, `port fix`, `port fix 2`, `service registry`, `provider fix`) — each surfaced by running the new pipeline end-to-end.

### Phase 2 — Apply the new 2026 baseline + adapt

The new assignment baseline (the file `Azure-Assignment-Petfindrv2.pdf` and matching code) was dropped on top of the working infra. The IaC and workflows survived; the app code was replaced. Adaptation work:

- `secrets fix` — adjustments to `secrets.bicep` to line up cvapi keys with what the new `app.py` reads.
- `bicep fix` — bicep adjustments.
- `containerTag` parameterisation — `app.bicep` previously hardcoded `containerTag: '1'` for both modules; the change forwards the build's commit-SHA / `'latest'` tag through `app.bicep` → `frontend.bicep` + `backend.bicep` so deployments actually pick up new images.

### Phase 3 — Operational debugging + reliability fixes

This phase corrected configuration and hardened the backend code:

**Imperative cluster fixes** (applied via `az` and `kubectl`):

- Patched the `cvapi` Kubernetes secret — `projectId` was a stale GUID; corrected to the real Custom Vision project id.
- `az storage account update --allow-blob-public-access true`, then `az storage container set-permission --public-access blob` on `images`. Without this, Custom Vision could not fetch the blob URLs the backend was sending it (it returned `BadRequestImageUrl`).

**Code change** (commit `improvements and changelog`):

- Added a `threading.Lock` around the `train → wait → unpublish → publish` block in `app.py`. Concurrent `/lostPet` submissions previously raced and most returned `BadRequestTrainInProgress` because Custom Vision allows only one active training per project.
- Replaced two hardcoded `time.sleep(300)` waits with `wait_for_training_completion()` — a 10-second poll on `GET /iterations/{id}` until `status == 'Completed'` (15-min timeout). Cuts ~8 minutes off each `/lostPet` flow for small projects.
- Added response-body logging (`| body: {_err_body(e)}`) to every `requests.exceptions.RequestException` handler, so future debugging doesn't require manual `kubectl exec` reproductions.
- Wrote [CHANGELOG.md](CHANGELOG.md) capturing all of the above plus recommended Bicep follow-ups.

## Future improvements

Three changes that would move the implementation from "demo-shaped" to "production-credible," ranked by impact.

### 1. Replace "one Custom Vision tag per pet" with image embeddings + vector search

The biggest blast-radius design choice. Custom Vision classification projects cap at **500 tags total**, and the model retrains on the full image set every time a new pet is added — so training time and cost grow linearly with the user base. With 100 pets the system already retrains for ~2 minutes per submission; at 500 it stops accepting new pets entirely. Softmax confidence across hundreds of classes also loses statistical meaning, so the 0.7 threshold becomes essentially noise.

The right primitive for "is this dog the same as that dog?" is **vector similarity, not classification**. Concretely: when a lost-pet image is uploaded, run it through Azure AI Vision Image Analysis 4.0's `vectorize-image` endpoint (a 1024-dim embedding) and store the vectors as a sub-array on the Cosmos document. Cosmos DB's vector search does a top-K nearest-neighbour query in O(log n) over millions of records. No retraining ever — embeddings are one-shot, deterministic, and the model itself is shared and pretrained.

Trade-off: the "tag-name = pet id" trick that currently lets predict skip a join goes away. Replaced by reading the matched record's id directly from the vector hit. Net result: scales from "500 pets total" to "millions" while *removing* infrastructure complexity (no more per-project Custom Vision lifecycle, no more train/publish/unpublish dance, no more `iteration_publish_name` global state).

### 2. SAS tokens for blob access — re-private the storage account

Anonymous blob access was enabled to unblock Custom Vision, which means **any GUID URL is now permanently leakable**. Pet photos can contain license tags, addresses in the background, owners' kids — and Azure storage offers no recall mechanism. Once a URL is out, it's out.

The fix is ~15 lines in `app.py`: inject the storage `accountKey` env var (the secret already exists in [iac/app/backend.bicep](iac/app/backend.bicep)), then before each Custom Vision call generate a 15-minute read SAS:

```python
from azure.storage.blob import BlobSasPermissions, generate_blob_sas
from datetime import datetime, timedelta, timezone

def signed_image_url(blob_name):
    sas = generate_blob_sas(
        account_name=storage_account_name, container_name="images",
        blob_name=blob_name, account_key=storage_account_key,
        permission=BlobSasPermissions(read=True),
        expiry=datetime.now(timezone.utc) + timedelta(minutes=15),
    )
    return f"https://{storage_account_name}.blob.core.windows.net/images/{blob_name}?{sas}"
```

Custom Vision happily accepts SAS-suffixed URLs. Then revert the storage account: `--allow-blob-public-access false` and container `--public-access None`. Same external behaviour, far smaller exposure window.

### 3. Atomic publish swap + idempotency on retry

Two latent reliability bugs the Phase 3 lock didn't fix:

- **Publish gap.** The current sequence is *unpublish previous → publish new*. Between those two HTTP calls — usually milliseconds, but seconds under load — there is **no published iteration**, and any `/foundPet` that hits during that window 404s. The fix is to swap the order: publish the new iteration under a *fresh* name (e.g. `pub-{iteration_id}`), update the predict path to read the latest publish-name from Cosmos, then unpublish the old. Atomic from the predict side.
- **Lost work on pod restart.** The Flask handler does `executor.submit(...)` and *immediately* returns 200 — Service Bus considers the message delivered. If the pod crashes 100ms later, that pet is silently never trained. The standard fix is to ack only after the unit of work commits, or write an `in_progress` marker to Cosmos before the ack with a janitor sweep on startup. Cheapest fix: before doing work, check whether `published_db_iteration_id` already covers this pet's tag — gives idempotency on retries with no infra change.

Order of operations: do **#2** first (lowest risk, biggest security improvement), then **#3** (afternoon-sized), then **#1** when usage justifies the rewrite.

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

## Pausing to Save Credits

When you're not actively using the app, stop the AKS cluster to deallocate the node VMs (the largest cost). Cosmos DB, Service Bus, and Storage still accrue small charges, but no re-setup is needed — `az aks start` brings everything back exactly as it was.

```powershell
az aks stop --resource-group petfaindr-rg --name petfaindraks
```

Resume later with:

```powershell
az aks start --resource-group petfaindr-rg --name petfaindraks
```
