#!/bin/bash
# Login to a HyperFleet hosted cluster using Google OIDC authentication.
#
# Usage:
#   ./login-cluster.sh <cluster-name-or-id>
#
# Prerequisites:
#   - gcloud CLI authenticated (gcloud auth login)
#   - kubectl installed
#   - Port-forward to hyperfleet-api running, or API accessible
#
# How it works:
#   1. Queries the HyperFleet API for the cluster's API endpoint
#   2. Obtains a Google ID token via gcloud
#   3. Sets up a kubectl context for the hosted cluster
#
# The hosted cluster uses Google OIDC with:
#   - Issuer: https://accounts.google.com
#   - Audience: 32555940559.apps.googleusercontent.com (default gcloud client ID)
#   - Username claim: email (e.g. user@redhat.com)
#   - Groups claim: hd (e.g. redhat.com)
#
# RBAC: The RBAC setup job grants cluster-admin to the redhat.com domain
# group and the cluster creator.
#
# Example:
#   ./login-cluster.sh ck0429g
#   ./login-cluster.sh 2q076tuskhl4h0grmmu438cdckis3ljr

set -euo pipefail

CLUSTER="${1:?Usage: $0 <cluster-name-or-id>}"
API_PORT="${HYPERFLEET_API_PORT:-8000}"
API_HOST="${HYPERFLEET_API_HOST:-localhost}"
API_BASE="http://${API_HOST}:${API_PORT}/api/hyperfleet/v1"

# Resolve cluster ID if a name was given
if [[ ${#CLUSTER} -lt 30 ]]; then
  echo "Looking up cluster by name: ${CLUSTER}"
  CLUSTER_DATA=$(curl -sf "${API_BASE}/clusters?search=name+%3D+%27${CLUSTER}%27" 2>/dev/null || true)
  if [[ -z "$CLUSTER_DATA" ]]; then
    echo "Starting port-forward to hyperfleet-api..."
    kubectl port-forward svc/hyperfleet-api -n hyperfleet ${API_PORT}:8000 > /dev/null 2>&1 &
    PF_PID=$!
    trap "kill $PF_PID 2>/dev/null" EXIT
    sleep 3
    CLUSTER_DATA=$(curl -sf "${API_BASE}/clusters?search=name+%3D+%27${CLUSTER}%27")
  fi
  CLUSTER_ID=$(echo "$CLUSTER_DATA" | python3 -c "
import sys, json
data = json.load(sys.stdin)
items = data.get('items', [])
if items:
    print(items[0]['id'])
" 2>/dev/null || true)

  if [[ -z "$CLUSTER_ID" ]]; then
    echo "Error: cluster '${CLUSTER}' not found"
    exit 1
  fi
  echo "  Cluster ID: ${CLUSTER_ID}"
else
  CLUSTER_ID="$CLUSTER"
fi

# Get the API endpoint from adapter statuses
echo "Fetching cluster API endpoint..."
STATUSES=$(curl -sf "${API_BASE}/clusters/${CLUSTER_ID}/statuses" 2>/dev/null || true)
if [[ -z "$STATUSES" ]]; then
  echo "Starting port-forward to hyperfleet-api..."
  kubectl port-forward svc/hyperfleet-api -n hyperfleet ${API_PORT}:8000 > /dev/null 2>&1 &
  PF_PID=$!
  trap "kill $PF_PID 2>/dev/null" EXIT
  sleep 3
  STATUSES=$(curl -sf "${API_BASE}/clusters/${CLUSTER_ID}/statuses")
fi

API_ENDPOINT=$(echo "$STATUSES" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for item in data.get('items', []):
    if item.get('adapter') == 'hc-adapter':
        ep = item.get('data', {}).get('hostedCluster', {}).get('apiEndpoint', '')
        if ep:
            print(ep)
            break
" 2>/dev/null)

if [[ -z "$API_ENDPOINT" ]]; then
  echo "Error: API endpoint not available yet (hc-adapter may still be provisioning)"
  exit 1
fi

CLUSTER_NAME=$(echo "$STATUSES" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for item in data.get('items', []):
    if item.get('adapter') == 'hc-adapter':
        print(item.get('data', {}).get('hostedCluster', {}).get('name', ''))
        break
" 2>/dev/null)
CLUSTER_NAME="${CLUSTER_NAME:-$CLUSTER}"

echo "  API Endpoint: ${API_ENDPOINT}"
echo "  Cluster Name: ${CLUSTER_NAME}"

# Get Google ID token
echo "Obtaining Google ID token..."
TOKEN=$(gcloud auth print-identity-token)

# Set up kubectl context
CONTEXT_NAME="hyperfleet-${CLUSTER_NAME}"
echo "Configuring kubectl context: ${CONTEXT_NAME}"

kubectl config set-cluster "${CONTEXT_NAME}" \
  --server="${API_ENDPOINT}" \
  --insecure-skip-tls-verify=true > /dev/null

kubectl config set-credentials "${CONTEXT_NAME}" \
  --token="${TOKEN}" > /dev/null

kubectl config set-context "${CONTEXT_NAME}" \
  --cluster="${CONTEXT_NAME}" \
  --user="${CONTEXT_NAME}" > /dev/null

kubectl config use-context "${CONTEXT_NAME}" > /dev/null

# Verify access
echo ""
echo "=== Connected ==="
kubectl auth whoami 2>/dev/null || true
echo ""
echo "Access: $(kubectl auth can-i '*' '*' 2>/dev/null && echo 'cluster-admin' || echo 'limited')"
echo ""
echo "Context '${CONTEXT_NAME}' is active. Run kubectl commands normally."
echo ""
echo "Note: The token expires after ~1 hour. Re-run this script to refresh."
