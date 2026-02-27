# adapter-hc: HostedCluster Provisioning Adapter

This adapter creates HostedCluster resources on GCP management clusters in response to cluster events from the HyperFleet API.

## Overview

When a new cluster is created in the HyperFleet API, the Sentinel publishes a reconcile event. This adapter:

1. Receives the event via Pub/Sub
2. Validates preconditions (cluster exists, not yet Ready)
3. Creates a Namespace for the hosted cluster
4. Creates a HostedCluster CR on the management cluster
5. Reports status back to the HyperFleet API

## Files

| File | Description |
|------|-------------|
| `values.yaml` | Helm values for the hyperfleet-adapter chart |
| `adapter-config.yaml` | Adapter deployment config (clients, broker, Kubernetes settings) |
| `adapter-task-config.yaml` | Task config with params, preconditions, resources, and post-processing |
| `adapter-task-resource-hostedcluster.yaml` | HostedCluster manifest template applied to the management cluster |

## Usage

These files are used with the upstream [hyperfleet-adapter](https://github.com/openshift-hyperfleet/hyperfleet-adapter) Helm chart.

```bash
helm install adapter-hc \
  https://github.com/openshift-hyperfleet/hyperfleet-adapter/charts \
  -f charts/adapter-hc/values.yaml \
  --namespace hyperfleet \
  --set broker.googlepubsub.projectId=<gcp-project>
```

## RBAC

The adapter requires permissions to create:
- `Namespaces` (core API)
- `ConfigMaps` (core API)
- `Secrets` (core API)
- `HostedClusters` (hypershift.openshift.io) -- add via `rbac.rules` in values

## Configuration

Update `values.yaml` with your environment-specific settings:

- `broker.googlepubsub.projectId` - GCP project ID
- `broker.googlepubsub.subscriptionId` - Pub/Sub subscription name
- `image.tag` - Adapter container image tag
