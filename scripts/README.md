# HyperFleet GCP Adapters — Dev Testing Guide

## What is HyperFleet?

HyperFleet is a cluster lifecycle management system for provisioning and managing OpenShift Hosted Control Planes (HCP) on GCP at scale. It uses an event-driven adapter architecture where a central API stores cluster state, a sentinel publishes reconcile events via GCP Pub/Sub, and independent config-driven adapters execute specific lifecycle tasks.

### Architecture Overview

```
User → HyperFleet API (CRUD) → Sentinel (polls + publishes CloudEvents) → GCP Pub/Sub (fan-out)
    ↑                                                                            │
    │ POST /statuses                                    ┌────────────────────────┼──────────────────────┐
    │                                                   ↓                        ↓                      ↓
    └──────────────────────────────────────── adapter-placement-job    adapter-signing-key         adapter-hc
                                              (select MC via Job)      (keygen via Maestro)      (HC via Maestro)
                                                     │                        │                       │
                                                     │               ┌────────┴───────┐      ┌────────┴───────┐
                                                     │               ↓                ↓      ↓                ↓
                                                     │          Maestro Server   Maestro Server          Maestro Server
                                                     │               ↓                ↓                       ↓
                                                     │          Maestro Agent    Maestro Agent          Maestro Agent
                                                     │          (MC: keygen     (MC: apply              (MC: apply
                                                     │           Job + RBAC)     HostedCluster)          HostedCluster)
                                                     │               │                │                       │
                                                     ↓               ↓                ↓                       ↓
                                              HyperFleet API  ←───────────── status reports ─────────────────┘
```

Adapters are deployments of the same `hyperfleet-adapter` binary with different YAML configs (AdapterConfig + AdapterTaskConfig). Each adapter executes a 4-phase pipeline:

1. **params** — extract parameters from the event and environment
2. **preconditions** — fetch cluster data from the API, evaluate gates (CEL expressions)
3. **resources** — create/update resources (Kubernetes Job or Maestro ManifestWork)
4. **post** — evaluate status conditions (CEL), POST status to HyperFleet API

Every adapter reports three mandatory conditions: `Applied`, `Available`, `Health`.

### Responsibility Boundary

Adapters operate exclusively within Red Hat-managed infrastructure (region + MC clusters). They have no direct access to customer GCP projects. All customer-side setup (WIF, VPC, PSC, IAM) is a prerequisite completed before the cluster creation request.

```
CUSTOMER RESPONSIBILITY (via CLI)            RED HAT / ADAPTER RESPONSIBILITY
═════════════════════════════════            ════════════════════════════════

Customer GCP Project:                        Regional + MC Infrastructure:
  • Create WIF Pool + Provider                 • Select management cluster (placement)
  • Configure OIDC issuer URL                  • Generate signing keypair on MC
  • Grant WIF pool access to SAs               • Push public key to OIDC issuer bucket
  • Create VPC / subnets / PSC                 • Create HostedCluster on MC
  • Enable required GCP APIs                   • Provision pull secret (ESO)
  • IAM roles for control plane SAs            • Create NodePools on MC (planned)
  • Grant read-only access to RH               • Manage HC lifecycle (update/delete)
    validation SA

  Done BEFORE calling create cluster         Done BY adapters AFTER cluster
                                             creation request
```

### Key Components

| Component | Location | Purpose |
|-----------|----------|---------|
| **HyperFleet API** | `hyperfleet` ns on region cluster | Stateless REST API — pure CRUD + status storage in PostgreSQL |
| **Sentinel** | `hyperfleet` ns on region cluster | Watches API for changes, publishes `Cluster.reconcile` CloudEvents to Pub/Sub |
| **Maestro Server** | `hyperfleet` ns on region cluster | Receives ManifestWork bundles from adapters, routes them to target MCs via gRPC + Pub/Sub |
| **Maestro Agent** | `maestro` ns on management cluster | Applies ManifestWork resources on MC, reports status back to Maestro Server via Pub/Sub |
| **GCP Adapters** | `hyperfleet` ns on region cluster | Subscribe to Pub/Sub events, execute tasks, report status to HyperFleet API |

### Infrastructure Layout

```
Region Cluster (GKE Autopilot, one per region)
├── HyperFleet core (API, Sentinel)
├── GCP HCP Adapters (adapter-placement-job, adapter-signing-key, adapter-hc)
├── Adapter GCP resources (adapter-resources chart: SAs, WIF, Pub/Sub subscriptions)
├── Maestro Server
└── Region GCP resources: Maestro Pub/Sub topics, Cloud SQL, HyperFleet Pub/Sub topic

Management Cluster (GKE, one or more per region)
├── Maestro Agent  ← receives ManifestWork, applies resources, reports status
├── HyperShift Operator
└── HostedCluster workloads (namespaces: clusters-{clusterId})
```

### Maestro Messaging Layer

Maestro replaces direct kubeconfig-based access with asynchronous GCP Pub/Sub channels, removing cross-cluster network dependencies. It uses 4 shared Pub/Sub topics per region:

| Topic | Direction | Purpose |
|-------|-----------|---------|
| `sourceevents` | Server → Agent | Targeted work delivery (filtered per MC via subscription) |
| `sourcebroadcast` | Server → All Agents | Broadcast commands |
| `agentevents` | Agent → Server | Status updates |
| `agentbroadcast` | Agent → All Server instances | Status broadcast (HA) |

Agent isolation is achieved via **per-MC subscriptions** with Pub/Sub filters on the `ce-clustername` attribute — each agent only receives work intended for its MC.

A separate **HyperFleet Pub/Sub topic** (`hyperfleet-cluster-events`) is used for Sentinel → Adapter communication. Each adapter gets its own subscription with independent delivery.

### Consumer Registration

Each MC must be registered as a Maestro consumer before it can receive ManifestWork. A `maestro-consumer-registration` CronJob on the region cluster reconciles every 5 minutes:
1. Lists Secret Manager secrets labeled `maestro-consumer-name:*`
2. Compares against registered Maestro consumers
3. Registers any missing MCs

This is idempotent and self-healing — handles transient failures, Maestro restarts, and new MC onboarding automatically.

### Status Feedback Loop

The adapters close the status loop — there is no direct Maestro Server → HyperFleet API integration:

```
1. Adapter sends ManifestWork to Maestro Server
2. Maestro Server delivers to MC Agent via Pub/Sub (sourceevents topic)
3. Agent applies resources on MC, reports status back via Pub/Sub (agentevents topic)
4. Maestro Server stores status, streams it to adapter via gRPC CloudEvents
5. Adapter discovers resource status (ManifestWork conditions + statusFeedback)
6. Adapter evaluates CEL expressions against discovered status
7. Adapter POSTs evaluated conditions to HyperFleet API: POST /clusters/{id}/statuses
```

---

## GCP Adapters

All adapters run on the **region cluster** in the `hyperfleet` namespace. They subscribe to the same Pub/Sub topic (`hyperfleet-cluster-events`) with separate subscriptions, so all adapters receive every event independently.

### Adapter Execution Order (Dependencies)

```
adapter-placement-job  ──→  adapter-signing-key  ──→  adapter-hc  ──→  adapter-nodepool (planned)
(select MC)                 (generate keys on MC)      (create HC)      (create NodePools)
```

Each adapter gates on the previous adapter's status via CEL preconditions:
- `adapter-signing-key` waits for `adapter-placement-job` to set `data.managementClusterName`
- `adapter-hc` waits for both placement decision AND `adapter-signing-key` Available=True
- Placement is **sticky** — once decided, the MC assignment does not change on spec updates

**Planned adapters** (not yet implemented):
- `validation-adapter` — validates customer GCP project setup (APIs, WIF, VPC, IAM) before placement
- `adapter-nodepool` — creates NodePool CRs on the MC after HostedCluster is available

### 1. adapter-placement-job

**Purpose**: Select a management cluster (MC) for a new hosted cluster.

**How it works**:
1. Receives `Cluster.reconcile` event
2. Fetches cluster details from HyperFleet API (precondition)
3. Checks if placement already decided — if yes, skips (gate closes, idempotent)
4. Creates a Kubernetes Job on the region cluster that:
   - Queries GCP Secret Manager for MC secrets (labeled `maestro-consumer-name`)
   - Queries Maestro API for registered consumers
   - Cross-checks both lists — an MC is eligible only if it appears in **both** sources
   - If multiple eligible: queries HyperFleet API for cluster counts per MC, picks least-loaded
   - If single eligible: skips the HyperFleet API query (optimization)
   - Patches its own Job `.status.conditions` with the selected MC name
5. Reports placement status (including `data.managementClusterName`) to HyperFleet API

**MC Eligibility — Dual-Source Cross-Check**:

| Scenario | Secret Manager | Maestro Consumer | Eligible? |
|----------|---------------|-----------------|-----------|
| MC fully provisioned and healthy | present | present | **Yes** |
| MC provisioned but agent not connected | present | absent | **No** |
| MC being decommissioned | absent | present | **No** |
| MC being provisioned | absent | absent | **No** |

**Helm chart**: `charts/adapter-placement-job/`

**Key env vars**:
- `GCP_PROJECT_ID` — regional GCP project for Secret Manager lookups
- `MAESTRO_URL` — Maestro server HTTP endpoint
- `HYPERFLEET_API_URL` — HyperFleet API endpoint for least-loaded query

### 2. adapter-signing-key

**Purpose**: Generate an RSA signing keypair for the HostedCluster's API server on the MC.

**Security model**: Private key material never flows through HyperFleet API, Maestro payloads, or Pub/Sub. The adapter sends only resource definitions (Job, RBAC) via Maestro — key generation happens entirely on the MC.

**How it works**:
1. Receives `Cluster.reconcile` event
2. Fetches cluster details and placement status from HyperFleet API
3. Gates on: placement decided AND cluster not Ready
4. Sends a ManifestWork to the target MC (via Maestro) containing:
   - Namespace (`clusters-{clusterId}`)
   - ServiceAccount with WIF annotation (GCS write access for issuer bucket)
   - RBAC (Role + RoleBinding for creating Secrets in namespace)
   - Keygen Job — generates RSA keypair, creates K8s Secret (private key stays on MC), uploads JWKS to GCS issuer bucket
5. Monitors Job completion via Maestro statusFeedback
6. Reports signing key status (Applied, Available, Health) to HyperFleet API

**Idempotency**: The keygen Job checks if the K8s Secret already exists before generating. If present and valid, it exits successfully without regenerating.

**Helm chart**: `charts/adapter-signing-key/`

**Key env vars**:
- `KEYGEN_IMAGE` — container image for keygen Job (default: `google/cloud-sdk:slim`)
- `KEYGEN_GCP_SA` — GCP SA email with GCS write access to OIDC issuer bucket

### 3. adapter-hc

**Purpose**: Create the HostedCluster and supporting resources on the management cluster.

**How it works**:
1. Receives `Cluster.reconcile` event
2. Fetches cluster details and adapter statuses from HyperFleet API
3. Gates on: placement decided AND signing key available AND cluster not Ready
4. Sends a ManifestWork to the target MC (via Maestro) containing:
   - Namespace (`clusters-{clusterId}`)
   - Pull secret (ExternalSecret from ClusterSecretStore → GCP Secret Manager)
   - Certificate (cert-manager, for API server TLS)
   - HostedCluster CR (`hypershift.openshift.io/v1beta1`) with full GCP platform spec, WIF config, network config
5. Reports HostedCluster status (Applied, Available, Health) to HyperFleet API via CEL expressions:
   - **Applied**: from ManifestWork `Applied` condition (Maestro agent accepted and applied)
   - **Available**: from HostedCluster's `Available` condition (via Maestro `statusFeedback.values`)
   - **Health**: inverse of HostedCluster's `Degraded` condition (via Maestro `statusFeedback.values`)

**Helm chart**: `charts/adapter-hc/`

**Key env vars**:
- `HC_RELEASE_IMAGE` — OpenShift release image (e.g. `quay.io/openshift-release-dev/ocp-release:4.20.0-x86_64`)
- `PULL_SECRET_STORE_NAME` — ClusterSecretStore name for pull secret (default: `gcp-secret-manager`)
- `PULL_SECRET_GCP_KEY` — GCP Secret Manager key for the pull secret (default: `default-openshift-pull-secret`)

### 4. adapter-resources

**Purpose**: Provisions GCP infrastructure for the adapters (not a runtime adapter itself).

**Creates via Config Connector**:
- GCP Service Account per adapter (with descriptive display name)
- Workload Identity Federation binding (K8s SA → GCP SA via IAMPolicyMember)
- Pub/Sub subscription per adapter (on `hyperfleet-cluster-events` topic)
- Pub/Sub IAM bindings (subscriber + viewer on subscription, viewer on topic)
- Extra project-level IAM roles where needed (e.g. `roles/secretmanager.viewer` for placement)

**Helm chart**: `charts/adapter-resources/`

---

## Dev Environment Setup

### Prerequisites

- `gcloud` CLI authenticated
- `kubectl` configured
- `helm` installed
- Access to the dev GCP projects

### Login to Clusters

```bash
# Login to region cluster
bash /Users/ckandaga/gcp-hcp/repos/ck-gcp-hcp-infra/terraform/config/dev-all-in-one/ckandag/login-region.sh

# Login to management cluster
bash /Users/ckandaga/gcp-hcp/repos/ck-gcp-hcp-infra/terraform/config/dev-all-in-one/ckandag/login-management.sh
```

### Deploy Adapters (Helm)

All adapters deploy to the `hyperfleet` namespace on the region cluster. Login to the region cluster first.

```bash
CHARTS_DIR=/Users/ckandaga/gcp-hcp/repos/ck-gcp-adapters/charts

# 1. Deploy adapter-resources (GCP infra — do this first)
helm upgrade --install adapter-resources "$CHARTS_DIR/adapter-resources" \
  -n hyperfleet --create-namespace

# 2. Deploy adapter-placement-job
helm upgrade --install adapter-placement-job "$CHARTS_DIR/adapter-placement-job" \
  -n hyperfleet \
  --set-file 'hyperfleet-adapter.adapterConfigFile=charts/adapter-placement-job/adapter-config.yaml' \
  --set-file 'hyperfleet-adapter.adapterTaskConfigFile=charts/adapter-placement-job/adapter-task-config.yaml'

# 3. Deploy adapter-signing-key
helm upgrade --install adapter-signing-key "$CHARTS_DIR/adapter-signing-key" \
  -n hyperfleet \
  --set-file 'hyperfleet-adapter.adapterConfigFile=charts/adapter-signing-key/adapter-config.yaml' \
  --set-file 'hyperfleet-adapter.adapterTaskConfigFile=charts/adapter-signing-key/adapter-task-config.yaml'

# 4. Deploy adapter-hc
helm upgrade --install adapter-hc "$CHARTS_DIR/adapter-hc" \
  -n hyperfleet \
  --set-file 'hyperfleet-adapter.adapterConfigFile=charts/adapter-hc/adapter-config.yaml' \
  --set-file 'hyperfleet-adapter.adapterTaskConfigFile=charts/adapter-hc/adapter-task-config.yaml'
```

After deploying, **always restart adapter pods** if ConfigMaps changed (Helm does not auto-restart on ConfigMap updates):

```bash
kubectl rollout restart deploy/adapter-placement-job-hyperfleet-adapter -n hyperfleet
kubectl rollout restart deploy/adapter-signing-key-hyperfleet-adapter -n hyperfleet
kubectl rollout restart deploy/adapter-hc-hyperfleet-adapter -n hyperfleet
```

---

## Testing Cluster Creation

### Step 1: Port-forward to HyperFleet API

```bash
kubectl port-forward svc/hyperfleet-api 8000:8000 -n hyperfleet &
```

### Step 2: Create a Cluster Payload

Create a JSON file (see `hc-test12-payload.json` for reference). Key fields:

```json
{
  "name": "hc-test12",
  "labels": {
    "env": "dev",
    "test": "v0.1.1-e2e",
    "shard": "1"
  },
  "spec": {
    "infraID": "hctest12",
    "issuerURL": "https://storage.googleapis.com/hctest12-oidc-issuer",
    "platform": {
      "type": "GCP",
      "gcp": {
        "projectID": "dev-mgt-us-c1-ckandag910f",
        "region": "us-central1",
        "network": "dev-mgt-us-c1-vpc",
        "subnet": "dev-mgt-us-c1-vpc-psc-subnet-0",
        "endpointAccess": "Private",
        "workloadIdentity": {
          "projectNumber": "165380755215",
          "poolID": "hctest12-wi-pool",
          "providerID": "hctest12-k8s-provider",
          "serviceAccountsRef": {
            "controlPlaneEmail": "...",
            "nodePoolEmail": "...",
            "cloudControllerEmail": "...",
            "storageEmail": "...",
            "imageRegistryEmail": "..."
          }
        }
      }
    },
    "clusterID": "93fdfa30-ca4c-4d6e-b47e-bee189e08254"
  },
  "kind": "Cluster"
}
```

**Important**: `spec.clusterID` must be a valid RFC4122 UUID (hex chars only, 8-4-4-4-12 format). Generate one with:

```bash
python3 -c "import uuid; print(uuid.uuid4())"
```

### Step 3: Create the Cluster

```bash
./create-cluster.sh hc-test12-payload.json
```

Or manually:

```bash
curl -s -X POST http://localhost:8000/api/hyperfleet/v1/clusters \
  -H "Content-Type: application/json" \
  -d @hc-test12-payload.json | python3 -m json.tool
```

### Step 4: Monitor Adapter Statuses

After creation, the Sentinel publishes a `Cluster.reconcile` event. All three adapters receive it, but only `adapter-placement-job` will proceed initially (the others gate on placement + signing key).

```bash
# Check cluster list via API
curl -s http://localhost:8000/api/hyperfleet/v1/clusters | python3 -m json.tool

# Check adapter statuses for a specific cluster
CLUSTER_ID="<cluster-id-from-api>"
curl -s "http://localhost:8000/api/hyperfleet/v1/clusters/${CLUSTER_ID}/statuses" | python3 -m json.tool
```

Expected progression:
1. `adapter-placement-job`: Applied=True, Available=True, data.managementClusterName=`<mc-name>`
2. `adapter-signing-key`: Applied=True, Available=True (keygen Job completed)
3. `adapter-hc`: Applied=True → Available=True (HostedCluster becomes available, may take 10-20 min)

### Step 5: Check Adapter Logs

```bash
# Placement adapter
kubectl logs -n hyperfleet -l app.kubernetes.io/instance=adapter-placement-job --tail=100

# Signing key adapter
kubectl logs -n hyperfleet -l app.kubernetes.io/instance=adapter-signing-key --tail=100

# HC adapter
kubectl logs -n hyperfleet -l app.kubernetes.io/instance=adapter-hc --tail=100

# Placement Job output (after it runs)
kubectl logs -n hyperfleet -l app=placement-job --tail=100
```

### Step 6: Verify on Management Cluster

Switch to the management cluster and check:

```bash
# Login to MC
bash /Users/ckandaga/gcp-hcp/repos/ck-gcp-hcp-infra/terraform/config/dev-all-in-one/ckandag/login-management.sh

# Check HostedClusters
kubectl get hostedclusters -A

# Check namespaces for your cluster
kubectl get ns | grep clusters-

# Check resources in the cluster namespace
kubectl get all,secrets,certificates -n clusters-<cluster-id>

# Check Maestro agent logs for ManifestWork apply status
kubectl logs -n maestro -l app=maestro-agent --tail=200
```

---

## Debugging

### Common Issues

#### HyperFleet API returns empty clusters / 500 errors
The dev PostgreSQL uses ephemeral storage (no PVC). GKE Autopilot regularly rotates nodes, which kills the postgres pod and loses all data. The `db-migrate` init container re-creates the schema on restart, but cluster data is gone.

```bash
# Check pod age (recently restarted = data lost)
kubectl get pods -n hyperfleet -l app.kubernetes.io/name=hyperfleet-api

# If DB lost data, delete the API pod to trigger migration init container
kubectl delete pod -n hyperfleet -l app.kubernetes.io/name=hyperfleet-api
```

**Fix**: The hyperfleet-api Helm chart supports persistent storage via `database.postgresql.persistence.enabled`. Enable it to survive pod rescheduling:

```bash
helm upgrade hyperfleet-api <chart-path> \
  --set database.postgresql.persistence.enabled=true \
  --set database.postgresql.persistence.size=1Gi \
  --reuse-values
```

This creates a PVC with GKE's default `standard-rwo` storage class. Alternatively, for production use `database.external.enabled=true` with Cloud SQL.

#### Adapter events fail with "connection refused" to HyperFleet API
The API pod was down when the adapter received events. Events are already consumed from Pub/Sub and won't be redelivered automatically. You need to re-create the cluster (or trigger a new reconcile event) to restart the adapter pipeline.

#### HostedCluster validation error: "clusterID must be an RFC4122 UUID"
The `spec.clusterID` in your payload must be a proper UUID (hex characters only, 8-4-4-4-12 format). Generate one with `python3 -c "import uuid; print(uuid.uuid4())"`.

#### Adapter status stuck at "ManifestWorkNotApplied"
This means the adapter sent the ManifestWork to Maestro, but the Maestro agent hasn't reported back yet. Check:

1. **Maestro agent on the MC** — is the agent running and connected?
   ```bash
   # Login to MC, then:
   kubectl logs -n maestro -l app=maestro-agent --tail=200
   ```
2. **Maestro consumer registration** — is the MC registered as a consumer?
   ```bash
   # From region cluster:
   kubectl port-forward svc/maestro 8001:8000 -n hyperfleet &
   curl -s http://localhost:8001/api/maestro/v1/consumers | python3 -m json.tool
   ```
3. **Pub/Sub subscriptions** — do per-MC subscriptions exist?
   ```bash
   gcloud pubsub subscriptions list --project=dev-reg-us-c1-ckandag910f | grep sourceevents
   ```

#### Placement job says "No MC secrets in Secret Manager"
The regional GCP project needs secrets labeled with `maestro-consumer-name`. These are created by Terraform when provisioning an MC. Check:

```bash
gcloud secrets list --project=dev-reg-us-c1-ckandag910f --filter='labels.maestro-consumer-name:*'
```

#### Adapter pods not picking up config changes after `helm upgrade`
Helm does not auto-restart pods when only ConfigMaps change. Always run `kubectl rollout restart` after upgrading adapter charts:

```bash
kubectl rollout restart deploy/adapter-placement-job-hyperfleet-adapter -n hyperfleet
```

### Useful Commands

```bash
# List all pods in hyperfleet namespace
kubectl get pods -n hyperfleet

# Check Maestro consumers (from region cluster, separate port from HyperFleet API)
kubectl port-forward svc/maestro 8001:8000 -n hyperfleet &
curl -s http://localhost:8001/api/maestro/v1/consumers | python3 -m json.tool

# Check all adapter deployments
kubectl get deploy -n hyperfleet | grep adapter

# Watch placement jobs
kubectl get jobs -n hyperfleet -l hyperfleet.io/managed-by=adapter-placement-job

# Check Maestro resource bundles (ManifestWorks sent by adapters)
curl -s http://localhost:8001/api/maestro/v1/resource-bundles | python3 -m json.tool

# Tail all adapter logs simultaneously
kubectl logs -n hyperfleet -l app.kubernetes.io/component=adapter --tail=50 -f
```

---

## References

### Implementation Plans
- [GCP-478: Adapter Design](../../../ck-gcp-hcp/implementation-plans/gcp-478-hyperfleet-adapters.md)
- [GCP-334: Maestro Setup](../../../ck-gcp-hcp/implementation-plans/gcp-334-hyperfleet-maestro-setup.md)

### Local Repositories

| Repo | Local Path | Purpose |
|------|-----------|---------|
| **ck-gcp-adapters** | `/Users/ckandaga/gcp-hcp/repos/ck-gcp-adapters` | GCP adapter Helm charts (this repo) |
| **ck-maestro** | `/Users/ckandaga/gcp-hcp/repos/ck-maestro` | Maestro server + agent (fork) |
| **hyperfleet-adapter** | `/Users/ckandaga/gcp-hcp/repos/hyperfleet-adapter` | Adapter framework binary (shared by all adapters) |
| **hyperfleet-api** | `/Users/ckandaga/gcp-hcp/repos/hyperfleet-api` | HyperFleet REST API |
| **hyperfleet-sentinel** | `/Users/ckandaga/gcp-hcp/repos/hyperfleet-sentinel` | Sentinel — watches API, publishes events to Pub/Sub |
| **hyperfleet-chart** | `/Users/ckandaga/gcp-hcp/repos/hyperfleet-chart` | Umbrella Helm chart for HyperFleet deployment |
| **hyperfleet-architecture** | `/Users/ckandaga/gcp-hcp/repos/hyperfleet-architecture` | Architecture docs, adapter framework design, Maestro integration guide |
| **ck-gcp-hcp-infra** | `/Users/ckandaga/gcp-hcp/repos/ck-gcp-hcp-infra` | Terraform modules, ArgoCD configs, Helm charts for GCP HCP infrastructure |
| **ck-gcp-hcp** | `/Users/ckandaga/gcp-hcp/repos/ck-gcp-hcp` | GCP HCP team workspace — implementation plans, scripts |

### Upstream
- [HyperFleet Architecture](https://github.com/openshift-hyperfleet/architecture)
- [Adapter Framework](https://github.com/openshift-hyperfleet/architecture/tree/main/hyperfleet/components/adapter/framework)
- [Maestro Upstream](https://github.com/openshift-online/maestro)
