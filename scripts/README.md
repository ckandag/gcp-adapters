# HyperFleet Dev Testing Playbook

## Architecture

HyperFleet provisions OpenShift Hosted Control Planes (HCP) on GCP at scale using an event-driven adapter architecture.

```
User → HyperFleet API (CRUD) → Sentinel (polls + publishes CloudEvents) → GCP Pub/Sub
  ↑                                                                            │
  │ POST /statuses                                      ┌──────────────────────┤
  │                                                     ↓                      ↓
  └──────────────────────────────────── adapter-placement-job            adapter-hc
                                        (select MC via Job)       (HC via Maestro → MC)
                                               │                          │
                                               ↓                          ↓
                                        HyperFleet API            Maestro Server → Agent
                                                                  (applies HC on MC)
```

### Components

| Component | Runs on | Purpose |
|---|---|---|
| HyperFleet API | Region cluster (`hyperfleet` ns) | Stateless CRUD + status storage (PostgreSQL) |
| Sentinel | Region cluster (`hyperfleet` ns) | Watches API, publishes `Cluster.reconcile` CloudEvents to Pub/Sub |
| Maestro Server | Region cluster (`hyperfleet` ns) | Routes ManifestWork to MCs via gRPC + Pub/Sub |
| Maestro Agent | Management cluster (`maestro` ns) | Applies ManifestWork, reports status back |
| Adapters | Region cluster (`hyperfleet` ns) | Subscribe to Pub/Sub, execute tasks, report status to API |

### Adapter Execution Order

```
placement-adapter → hc-adapter
(select MC)         (create HostedCluster via Maestro)
```

Each adapter gates on the previous via CEL preconditions. Placement is sticky — once decided, the MC assignment doesn't change.

### Key IDs

| Field | Format | Source | Example |
|---|---|---|---|
| `id` | UUIDv7 | HyperFleet API (auto-generated) | `019df41a-e34c-7595-a3d6-e143f28eb106` |
| `spec.clusterID` | RFC4122 UUID | Client payload OR fallback to `id` | `19ae7094-f73a-41e0-af10-89289d8f75a8` |
| `spec.infraID` | Short alphanumeric | Client payload | `hctest24` |

With HyperFleet API v0.2.1+, the `id` field is a UUIDv7 (valid RFC4122). If `spec.clusterID` is omitted from the payload, the HC adapter's CEL expression `spec.?clusterID.orValue(id)` falls back to `id`, which now passes HyperShift's UUID validation. You no longer need to generate `clusterID` client-side.

---

## Login to Clusters

```bash
# Region cluster (where HyperFleet core + adapters run)
bash /Users/ckandaga/gcp-hcp/repos/ck-gcp-hcp-infra/terraform/config/dev-all-in-one/ckandag/login-region.sh

# Management cluster (where HostedClusters run)
bash /Users/ckandaga/gcp-hcp/repos/ck-gcp-hcp-infra/terraform/config/dev-all-in-one/ckandag/login-management.sh
```

---

## Patching / Updating Components

All HyperFleet components are deployed via ArgoCD on the region cluster. Configuration lives in two places:

- **ArgoCD templates**: `ck-gcp-hcp-infra/.worktree/dev-ckandag/argocd/config/region/<component>/template.yaml`
- **Helm chart values**: `ck-gcp-hcp-infra/helm/charts/<component>/values.yaml` (for infra-managed charts like adapters)

### How to Update a Component Version

1. **Edit the ArgoCD template** — change `targetRevision` and `image.tag`:

```bash
# Example: bump hyperfleet-api from v0.2.0 to v0.2.1
# In argocd/config/region/hyperfleet-api/template.yaml:
#   targetRevision: 'v0.2.1'
#   image.tag: "v0.2.1"
```

2. **Render** — ArgoCD reads rendered files, not config:

```bash
cd /Users/ckandaga/gcp-hcp/repos/ck-gcp-hcp-infra/.worktree/dev-ckandag/argocd
uv run scripts/render.py
```

3. **Commit and push**:

```bash
cd /Users/ckandaga/gcp-hcp/repos/ck-gcp-hcp-infra/.worktree/dev-ckandag
git add -A && git commit -m "chore: bump <component> to <version>" && git push
```

4. **Verify ArgoCD sync** (from region cluster):

```bash
kubectl get application <component> -n argocd \
  -o custom-columns='NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status'
```

5. **Force sync if needed** — ArgoCD may cache the old chart revision:

```bash
kubectl -n argocd patch application <component> --type merge \
  -p '{"operation":{"initiatedBy":{"username":"cli"},"sync":{"revision":"","syncStrategy":{"hook":{}}}}}'
```

6. **Verify the image rolled out**:

```bash
kubectl get deployments -n hyperfleet \
  -o custom-columns='NAME:.metadata.name,IMAGE:.spec.template.spec.containers[0].image,READY:.status.readyReplicas'
```

7. **Restart pods if the image didn't change** (e.g. config-only update):

```bash
kubectl rollout restart deployment/<component> -n hyperfleet
kubectl rollout status deployment/<component> -n hyperfleet --timeout=60s
```

### Component Template Locations

| Component | ArgoCD Template |
|---|---|
| hyperfleet-api | `argocd/config/region/hyperfleet-api/template.yaml` |
| hyperfleet-sentinel | `argocd/config/region/hyperfleet-sentinel/template.yaml` |
| hyperfleet-hc-adapter | `argocd/config/region/hyperfleet-hc-adapter/template.yaml` |
| hyperfleet-placement-adapter | `argocd/config/region/hyperfleet-placement-adapter/template.yaml` |

### Overriding HC Adapter Env Vars

The HC adapter supports env var overrides in its ArgoCD template under `hyperfleet-adapter.env`. Useful for testing custom images:

```yaml
env:
  - name: HC_RELEASE_IMAGE
    value: "quay.io/openshift-release-dev/ocp-release:4.22.0-ec.4-x86_64"
  - name: HC_CPO_IMAGE
    value: ""  # set a custom CPO image here to override
  - name: HC_CAPG_IMAGE
    value: ""  # set a custom CAPG image here to override
  - name: HC_CONTROLLER_AVAILABILITY_POLICY
    value: "HighlyAvailable"
```

After editing, render → push → verify sync → restart pod.

---

## Creating a Test Cluster

### Prerequisites

- Logged in to **region cluster** (`login-region.sh`)
- Port-forward to HyperFleet API running (scripts auto-start it if needed)
- GCP infrastructure set up for the cluster (`setup-infra.sh`)

### Quick Path (end-to-end)

```bash
cd /Users/ckandaga/gcp-hcp/hcp-workdir/hyperfleet/scripts

# One command: setup infra + generate payload + create cluster
./e2e-create-cluster.sh hctest30 ck-hcp-test --signing-key
```

### Step-by-Step Path

#### 1. Setup GCP Infrastructure (one-time per infra-id)

Creates WIF pool/provider, IAM service accounts, VPC/subnet:

```bash
./setup-infra.sh hctest30 ck-hcp-test
```

Output goes to `output/hctest30/` (iam-config.json, infra-config.json, signing key).

#### 2. Generate Cluster Payload

```bash
./gen-payload.sh hctest30 --signing-key
```

This produces `hctest30-payload.json`. Key options:
- `--infra-id <id>` — use a different infra-id (default: same as cluster name)
- `--network <name>` / `--subnet <name>` — override VPC (e.g. use MC's existing VPC)
- `--signing-key` — include the signing key in the payload
- `--endpoint-access Private` — private API endpoint

**Note on clusterID**: With API v0.2.1+, `spec.clusterID` is optional. If omitted, the adapter uses the HyperFleet `id` (UUIDv7) as `spec.clusterID`. The `gen-payload.sh` script has UUID generation commented out by default.

#### 3. Create the Cluster

```bash
./create-cluster.sh hctest30-payload.json
```

Save the `id` from the response — you'll need it for status checks.

---

## Checking Cluster Status After Creation

### The Right Way: API Status Endpoints

**Always use the HyperFleet API to check status.** Don't crawl adapter logs.

#### Port-forward (if not already running)

```bash
kubectl port-forward svc/hyperfleet-api 8000:8000 -n hyperfleet &
```

#### Get cluster details

```bash
CLUSTER_ID="019df41a-e34c-7595-a3d6-e143f28eb106"

curl -s "http://localhost:8000/api/hyperfleet/v1/clusters/${CLUSTER_ID}" | python3 -m json.tool
```

#### Get adapter statuses (the key endpoint)

```bash
curl -s "http://localhost:8000/api/hyperfleet/v1/clusters/${CLUSTER_ID}/statuses" | python3 -m json.tool
```

This returns all adapter reports for the cluster. Each adapter reports:
- **conditions**: `Applied`, `Available`, `Health` (each True/False/Unknown)
- **data**: adapter-specific output (MC name, API endpoint, etc.)
- **observed_generation**: which cluster generation was processed

#### Look up cluster by name

```bash
curl -s "http://localhost:8000/api/hyperfleet/v1/clusters?search=name+%3D+%27hctest27%27" | python3 -m json.tool
```

#### List all clusters

```bash
curl -s "http://localhost:8000/api/hyperfleet/v1/clusters" | python3 -m json.tool
```

### Expected Adapter Status Progression

After cluster creation, adapters execute in order. Check the `/statuses` endpoint periodically.

**1. Placement adapter** (seconds):

```json
{
  "adapter": "placement-adapter",
  "conditions": [
    { "type": "Applied",   "status": "True", "reason": "JobApplied" },
    { "type": "Available", "status": "True", "reason": "PlacementDecided" },
    { "type": "Health",    "status": "True", "reason": "Healthy" }
  ],
  "data": {
    "managementClusterName": "dev-mgt-us-c1-ckandagb3fc",
    "managementClusterNamespace": "clusters-019df41a-e34c-7595-a3d6-e143f28eb106",
    "baseDomain": "us-central1-ckandagb3fc-1.dev.gcp-hcp.devshift.net"
  }
}
```

**2. HC adapter** (seconds for Applied, 10-20 min for Available):

```json
{
  "adapter": "hc-adapter",
  "conditions": [
    { "type": "Applied",   "status": "True",  "reason": "AppliedManifestWorkComplete" },
    { "type": "Available", "status": "False", "reason": "HostedClusterNotAvailable" },
    { "type": "Health",    "status": "False", "reason": "HostedClusterDegraded" }
  ],
  "data": {
    "hostedCluster": {
      "name": "hctest27",
      "apiEndpoint": "https://api.hctest27-user.us-central1-...",
      "version": ""
    }
  }
}
```

Once the HostedCluster finishes provisioning (10-20 min), `Available` and `Health` flip to `True`.

### Verifying on the Management Cluster

After placement succeeds, switch to the MC to inspect the actual resources:

```bash
# Login to MC
bash /path/to/login-management.sh

# Check HostedClusters
kubectl get hostedclusters -A

# Check the cluster namespace
kubectl get all,secrets,certificates -n clusters-<cluster-id>

# Check Maestro agent status
kubectl logs -n maestro -l app=maestro-agent --tail=50
```

### Login to the Hosted Cluster

Once `hc-adapter` reports `Available=True`:

```bash
./login-cluster.sh hctest27
# or by ID:
./login-cluster.sh 019df41a-e34c-7595-a3d6-e143f28eb106
```

---

## Quick Reference Commands

### Status Checks (Region Cluster)

```bash
# Port-forward to API
kubectl port-forward svc/hyperfleet-api 8000:8000 -n hyperfleet &

# List clusters
curl -s http://localhost:8000/api/hyperfleet/v1/clusters | python3 -m json.tool

# Get cluster by ID
curl -s http://localhost:8000/api/hyperfleet/v1/clusters/${CLUSTER_ID} | python3 -m json.tool

# Get adapter statuses — THE primary status check
curl -s http://localhost:8000/api/hyperfleet/v1/clusters/${CLUSTER_ID}/statuses | python3 -m json.tool

# Search by name
curl -s "http://localhost:8000/api/hyperfleet/v1/clusters?search=name+%3D+%27hctest27%27" | python3 -m json.tool
```

### Deployment Checks (Region Cluster)

```bash
# All deployments with images
kubectl get deployments -n hyperfleet \
  -o custom-columns='NAME:.metadata.name,IMAGE:.spec.template.spec.containers[0].image,READY:.status.readyReplicas'

# ArgoCD application status
kubectl get applications -n argocd \
  -o custom-columns='NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status'

# All pods
kubectl get pods -n hyperfleet
```

### Management Cluster Checks

```bash
# HostedClusters
kubectl get hostedclusters -A

# Cluster namespaces
kubectl get ns | grep clusters-

# Resources in a cluster namespace
kubectl get all,secrets,certificates -n clusters-<cluster-id>

# Maestro agent logs
kubectl logs -n maestro -l app=maestro-agent --tail=50
```

### Adapter Logs (when API status isn't enough)

```bash
# Placement adapter
kubectl logs deploy/hyperfleet-placement-adapter-hyperfleet-adapter -n hyperfleet --tail=50

# HC adapter
kubectl logs deploy/hyperfleet-hc-adapter-hyperfleet-adapter -n hyperfleet --tail=50

# Filter for a specific cluster
kubectl logs deploy/hyperfleet-hc-adapter-hyperfleet-adapter -n hyperfleet --since=10m | grep <cluster-id>
```

### Maestro (Region Cluster)

```bash
# Port-forward to Maestro (separate from API)
kubectl port-forward svc/maestro 8001:8000 -n hyperfleet &

# List registered consumers (MCs)
curl -s http://localhost:8001/api/maestro/v1/consumers | python3 -m json.tool

# List resource bundles (ManifestWorks sent by adapters)
curl -s http://localhost:8001/api/maestro/v1/resource-bundles | python3 -m json.tool
```

---

## Debugging

### Adapter statuses endpoint returns 404

The cluster may not exist or may have been lost to DB reset. List clusters first:

```bash
curl -s http://localhost:8000/api/hyperfleet/v1/clusters | python3 -c "
import json, sys
data = json.load(sys.stdin)
for c in data.get('items', []):
    print(f\"{c['id']}  {c['name']}  gen={c['generation']}\")
"
```

### Adapter statuses show empty `items: []`

Adapters haven't processed the event yet. Wait 30-60 seconds for the sentinel to publish and adapters to pick up. If still empty after a few minutes, check adapter logs.

### DB lost data (PostgreSQL pod restarted)

Dev PostgreSQL uses ephemeral storage. Node rotation kills the pod and loses data. Re-create clusters after this happens.

```bash
# Check pod age
kubectl get pods -n hyperfleet -l app.kubernetes.io/name=hyperfleet-api
```

### HostedCluster validation error on MC

If the HostedCluster fails to create on the MC, check events:

```bash
# Login to MC, then:
kubectl get events -n clusters-<cluster-id> --sort-by=.lastTimestamp
```

Common cause: `spec.clusterID` not a valid UUID. With API v0.2.1+, omitting `clusterID` from the payload works because `id` is now UUIDv7.

### Adapter stuck on precondition

Adapters gate on predecessors. If HC adapter says "precondition not met", check placement status first:

```bash
curl -s http://localhost:8000/api/hyperfleet/v1/clusters/${CLUSTER_ID}/statuses | \
  python3 -c "
import json, sys
for s in json.load(sys.stdin).get('items', []):
    avail = next((c for c in s['conditions'] if c['type'] == 'Available'), {})
    print(f\"{s['adapter']:30s} Available={avail.get('status','?'):5s} ({avail.get('reason','')})\")"
```

### Config changes not taking effect

Helm/ArgoCD doesn't auto-restart pods on ConfigMap changes. Always restart:

```bash
kubectl rollout restart deployment/<component> -n hyperfleet
kubectl rollout status deployment/<component> -n hyperfleet --timeout=60s
```

---

## Scripts Reference

| Script | Purpose |
|---|---|
| `setup-infra.sh <id> <project>` | Create WIF pool, IAM SAs, VPC for a cluster |
| `gen-payload.sh <name> [opts]` | Generate cluster creation JSON payload |
| `create-cluster.sh <payload.json>` | POST payload to HyperFleet API |
| `e2e-create-cluster.sh <name> <project>` | All-in-one: infra + payload + create |
| `login-cluster.sh <name-or-id>` | Configure kubectl for a hosted cluster |

---

## OIDC Document Storage (GCS Bucket + Proxy)

### Background

For Workload Identity Federation (WIF) to work, GCP STS needs to fetch OIDC discovery documents from a publicly accessible HTTPS URL. The HyperShift Operator uploads these documents to a GCS bucket, and an nginx proxy pod fronts the private bucket to make them publicly reachable.

### How It Works

```
GCP STS / Any Client
        │
        ▼  (HTTPS)
GKE Ingress (Google-managed cert + global static IP)
        │
        ▼  (HTTP)
K8s Service → oidc-proxy pods (nginx + GCS Fuse CSI sidecar)
        │
        ▼  (Workload Identity)
Private GCS Bucket: dev-mgt-us-c1-ckandagb3fc-oidc-proxy-test
  ├── {infraID}/.well-known/openid-configuration
  └── {infraID}/openid/v1/jwks
```

The proxy pod runs in `oidc-system` namespace on the **management cluster**. It mounts the GCS bucket via GCS Fuse CSI driver (read-only) and serves documents through nginx.

### Key Resources

| Resource | Value |
|---|---|
| GCS Bucket | `dev-mgt-us-c1-ckandagb3fc-oidc-proxy-test` |
| Proxy namespace | `oidc-system` (on MC) |
| Proxy deployment | `oidc-proxy` (2 replicas) |
| Public endpoint | `https://oidc.dev-reg-us-c1-ckandagb3fc.dev.gcp-hcp.devshift.net/{infraID}` |
| MC project | `dev-mgt-us-c1-ckandagb3fc` |

### HyperShift Operator Configuration

The HO needs the `--gcp-oidc-storage-bucket-name` flag to enable OIDC document upload. This is configured in the ArgoCD template for HyperShift on the MC:

**File**: `ck-gcp-hcp-infra/.worktree/dev-ckandag/argocd/config/management-cluster/hypershift/template.yaml`

The kustomize patch adds the arg to the operator Deployment:

```yaml
- op: add
  path: /spec/template/spec/containers/0/args/-
  value: --gcp-oidc-storage-bucket-name=dev-mgt-us-c1-ckandagb3fc-oidc-proxy-test
```

Without this flag, the HO skips OIDC upload and logs an error (which doesn't surface as a visible condition).

### How the HO Upload Works (`gcp_oidc.go`)

On each HostedCluster reconcile, the HO checks:

1. If `ServiceAccountSigningKey` is set → **skip** (client manages OIDC docs)
2. If finalizer `hypershift.io/gcp-oidc-discovery` is present → **skip** (already uploaded)
3. If bucket name or GCS client is not configured → **error** (no-op without the flag)
4. Waits for `sa-signing-key` secret in the HCP namespace (contains the public key)
5. Generates OIDC discovery document and JWKS from the public key
6. Uploads to GCS: `gs://{bucket}/{infraID}/.well-known/openid-configuration` and `gs://{bucket}/{infraID}/openid/v1/jwks`
7. Adds finalizer `hypershift.io/gcp-oidc-discovery` to the HostedCluster

On deletion, the finalizer triggers cleanup — deletes the objects from GCS before removing the finalizer.

### Verifying OIDC Upload

```bash
# Check finalizer on the HostedCluster (on MC)
kubectl get hostedcluster <name> -n clusters-<id> -o jsonpath='{.metadata.finalizers}'
# Should contain: hypershift.io/gcp-oidc-discovery

# Check GCS bucket contents
gcloud storage ls gs://dev-mgt-us-c1-ckandagb3fc-oidc-proxy-test/<infraID>/

# View the discovery document
gcloud storage cat gs://dev-mgt-us-c1-ckandagb3fc-oidc-proxy-test/<infraID>/.well-known/openid-configuration

# Test via public proxy endpoint
curl -s https://oidc.dev-reg-us-c1-ckandagb3fc.dev.gcp-hcp.devshift.net/<infraID>/.well-known/openid-configuration | python3 -m json.tool
```

### Cluster Creation: With vs Without Signing Key

| Flag | OIDC Behavior | Use Case |
|---|---|---|
| `--signing-key` | Client provides key; HO **skips** OIDC upload | Legacy / client-managed OIDC |
| (no flag) | HO generates key, uploads OIDC docs to GCS | **Recommended** — HO manages OIDC lifecycle |

For testing HO-managed OIDC, create clusters **without** `--signing-key`:

```bash
./e2e-create-cluster.sh hctest31 ck-hcp-test
```

### IssuerURL Mismatch (Known Issue)

The `gen-payload.sh` script currently generates `issuerURL` as `https://storage.googleapis.com/{infraID}-oidc-issuer` (direct GCS URL). However, the actual documents are served via the proxy at `https://oidc.dev-reg-us-c1-ckandagb3fc.dev.gcp-hcp.devshift.net/{infraID}`. For STS to resolve correctly, the `issuerURL` in the HostedCluster spec should match the proxy endpoint. This needs to be fixed in `gen-payload.sh` for production use.

### Architecture Reference

See `ck-gcp-hcp/experiments/gcp-588-public-bucket/README.md` for the full design doc covering:
- Why public access is needed (GCP STS makes unauthenticated HTTPS requests)
- Org policy constraints blocking `allUsers` and CDN approaches
- The proxy pod workaround (current solution)
- CDN approach (blocked, pending org policy change)

---

## Repositories

| Repo | Purpose |
|---|---|
| **ck-gcp-hcp-infra** | Terraform + ArgoCD configs + Helm charts for infra |
| **hyperfleet-api** | HyperFleet REST API |
| **hyperfleet-sentinel** | Sentinel (watches API, publishes events) |
| **hyperfleet-adapter** | Adapter framework binary |
| **hyperfleet-chart** | Umbrella Helm chart |
| **ck-hypershift** | HyperShift operator (fork) |
| **ck-maestro** | Maestro server + agent (fork) |
