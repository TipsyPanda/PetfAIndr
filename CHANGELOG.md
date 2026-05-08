# Changelog

All notable changes to this project are documented here. Format roughly follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased] - 2026-05-08

### Backend — `container-images/backend/app.py`

#### Fixed
- **Concurrent `/lostPet` submissions no longer trample each other.** The Custom
  Vision train + unpublish + publish sequence is now serialized with a
  `threading.Lock`. Previously every submission ran in a `ThreadPoolExecutor`
  worker and called `POST /train` independently; Custom Vision permits only one
  active training per project, so all but the first returned
  `400 BadRequestTrainInProgress` and aborted before reaching publish — leaving
  no iteration named `publishediteration` for `/foundPet` to query.
- **Predictable training latency.** The two hardcoded `time.sleep(300)` waits
  (10 minutes total) after kicking off training are replaced with a poll on
  `GET /iterations/{id}` every 10 seconds until `status == "Completed"`
  (15-minute timeout). Small projects (a few tags, ~5 images each) typically
  finish in 1–2 minutes, so each `/lostPet` flow now publishes ~8 minutes
  earlier than before. If training never completes the run aborts cleanly
  instead of attempting to publish a non-existent iteration.

#### Improved
- **Custom Vision error logs now include the response body.** Every
  `requests.exceptions.RequestException` handler appends `| body: <text>`,
  surfacing Custom Vision error codes (`BadRequestImageUrl`,
  `BadRequestTrainInProgress`, `BadRequestIterationNotPublished`, etc.) in the
  pod logs. Before, only the HTTP status line was printed and root-causing
  failures required reproducing the call manually with `kubectl exec`.

### Operations (one-time, not version-controlled)

The following changes were applied imperatively while debugging and should be
reflected in IaC on the next infra deploy:

- `cvapi.projectId` Kubernetes secret updated to
  `5ca5cb65-73a4-4762-a7ad-631d7983763e` (was a stale project ID with a
  different model). The corresponding parameter in the secrets-deploy workflow
  must be updated so the next infra run does not revert it.
- Storage account `storepetfaindr`:
  `--allow-blob-public-access true` (was the implicit Azure default of `false`).
- Container `images` on `storepetfaindr`: `--public-access blob` (was `None`).
  Custom Vision fetches image URLs anonymously, so these two settings are
  required for both training image upload and prediction.

### Recommended Bicep updates (not yet applied)

To make the operational changes above durable, edit `iac/infra.bicep`:

```bicep
resource storageAccount 'Microsoft.Storage/storageAccounts@2022-05-01' = {
  // ...
  properties: {
    allowBlobPublicAccess: true
  }
}

resource imagesContainer ... {
  name: 'images'
  properties: { publicAccess: 'Blob' }   // was 'None'
}
```

If anonymous blob exposure is unacceptable, replace these with a SAS-token
flow in the backend before each Custom Vision call and revert the storage
account to private.

### Known limitations / open issues

- `iteration_publish_name` is still hardcoded to `"publishediteration"` and
  globally overwritten on each successful publish. Safe under the new lock,
  but offers no rollback if a publish fails after the previous iteration has
  already been unpublished.
- Backend runs `flask run --host=0.0.0.0` per the Dockerfile, but
  `app.run(port=app_port)` at module level binds to `127.0.0.1` during import
  and prevents `flask run` from ever taking over. This currently works because
  the Dapr sidecar shares the pod's network namespace; direct pod probes will
  not work.
- The "one Custom Vision tag per pet" design caps total pets at ~500
  (Custom Vision classification project tag limit) and grows training time
  roughly linearly. Not a problem for demo workloads, worth revisiting if
  scaled.
