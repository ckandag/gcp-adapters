#!/bin/bash
# Generate a HyperFleet cluster payload JSON from setup-infra.sh output.
#
# Reads iam-config.json and infra-config.json from the output directory,
# combines them with sensible defaults, and writes a ready-to-use payload.
#
# The cluster name is also used as the infra-id (and to locate the
# output/<cluster-name>/ directory from setup-infra.sh).
#
# Usage:
#   ./gen-payload.sh <cluster-name> [options]
#
# Options:
#   --infra-id <id>           Override infra-id (default: same as cluster-name)
#   --network <name>          VPC network name (default: from infra-config.json)
#   --subnet <name>           Subnet name (default: from infra-config.json)
#   --endpoint-access <mode>  Private or PublicAndPrivate (default: PublicAndPrivate)
#   --signing-key             Include base64-encoded signing key in spec.signingKey
#   --label <key=value>       Add a label (repeatable)
#   --test-label <value>      Shorthand for --label test=<value>
#   --output <path>           Output file path (default: <cluster-name>-payload.json)
#
# Examples:
#   # Minimal — uses cluster name as infra-id
#   ./gen-payload.sh hctest20
#
#   # Use a different infra-id (e.g. cluster name has hyphens)
#   ./gen-payload.sh hc-test20 --infra-id hctest20
#
#   # Override network (e.g. using MC's existing VPC)
#   ./gen-payload.sh hctest20 \
#     --network dev-mgt-us-c1-vpc --subnet dev-mgt-us-c1-vpc-psc-subnet-0
#
#   # Include the signing key so adapter-signing-key uses it instead of generating
#   ./gen-payload.sh hctest20 --signing-key --test-label "e2e-v2"

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
CLUSTER_NAME="${1:?Usage: $0 <cluster-name> [options]}"
shift 1

INFRA_ID=""
NETWORK_OVERRIDE=""
SUBNET_OVERRIDE=""
ENDPOINT_ACCESS="PublicAndPrivate"
INCLUDE_SIGNING_KEY=false
OUTPUT_FILE=""
EXTRA_LABELS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --infra-id)      INFRA_ID="$2"; shift 2 ;;
    --network)       NETWORK_OVERRIDE="$2"; shift 2 ;;
    --subnet)        SUBNET_OVERRIDE="$2"; shift 2 ;;
    --endpoint-access) ENDPOINT_ACCESS="$2"; shift 2 ;;
    --signing-key)   INCLUDE_SIGNING_KEY=true; shift ;;
    --label)         EXTRA_LABELS+=("$2"); shift 2 ;;
    --test-label)    EXTRA_LABELS+=("test=$2"); shift 2 ;;
    --output)        OUTPUT_FILE="$2"; shift 2 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

INFRA_ID="${INFRA_ID:-$CLUSTER_NAME}"

# ---------------------------------------------------------------------------
# Locate input files
# ---------------------------------------------------------------------------
INPUT_DIR="${SCRIPT_DIR}/output/${INFRA_ID}"
IAM_CONFIG="${INPUT_DIR}/iam-config.json"
INFRA_CONFIG="${INPUT_DIR}/infra-config.json"
SIGNING_KEY_B64="${INPUT_DIR}/signing-key-base64.txt"

if [[ ! -f "$IAM_CONFIG" ]]; then
  echo "ERROR: ${IAM_CONFIG} not found."
  echo "Run setup-infra.sh first: ./setup-infra.sh ${INFRA_ID} <project-id>"
  exit 1
fi

OUTPUT_FILE="${OUTPUT_FILE:-${SCRIPT_DIR}/${CLUSTER_NAME}-payload.json}"

# ---------------------------------------------------------------------------
# Build payload
# ---------------------------------------------------------------------------
python3 -c "
import json, sys, uuid, os

cluster_name   = sys.argv[1]
infra_id       = sys.argv[2]
endpoint       = sys.argv[3]
network_ovr    = sys.argv[4]
subnet_ovr     = sys.argv[5]
include_key    = sys.argv[6] == 'true'
output_file    = sys.argv[7]
iam_path       = sys.argv[8]
infra_path     = sys.argv[9]
key_path       = sys.argv[10]
extra_labels   = sys.argv[11:]

# Load IAM config
with open(iam_path) as f:
    iam = json.load(f)

# Load infra config (optional — network values can be overridden)
infra = {}
if os.path.exists(infra_path):
    with open(infra_path) as f:
        infra = json.load(f)

# Resolve values
project_id     = iam.get('projectId', infra.get('projectId', ''))
project_number = iam.get('projectNumber', '')
region         = infra.get('region', 'us-central1')
network        = network_ovr or infra.get('networkName', '')
subnet         = subnet_ovr or infra.get('subnetName', '')

# WIF fields from IAM config
pool = iam.get('workloadIdentityPool', {})
sas  = iam.get('serviceAccounts', {})

# Build labels
labels = {'env': 'dev', 'shard': '1'}
for lbl in extra_labels:
    if '=' in lbl:
        k, v = lbl.split('=', 1)
        labels[k] = v

# Build payload
payload = {
    'name': cluster_name,
    'labels': labels,
    'spec': {
        'infraID': infra_id,
        'issuerURL': f'https://hypershift-{infra_id}-oidc' if include_key else f'https://storage.googleapis.com/{infra_id}-oidc-issuer',
        'platform': {
            'type': 'GCP',
            'gcp': {
                'projectID': project_id,
                'region': region,
                'network': network,
                'subnet': subnet,
                'endpointAccess': endpoint,
                'workloadIdentity': {
                    'projectNumber': project_number,
                    'poolID': pool.get('poolId', ''),
                    'providerID': pool.get('providerId', ''),
                    'serviceAccountsRef': {
                        'controlPlaneEmail':    sas.get('ctrlplane-op', ''),
                        'nodePoolEmail':        sas.get('nodepool-mgmt', ''),
                        'cloudControllerEmail': sas.get('cloud-controller', ''),
                        'storageEmail':         sas.get('gcp-pd-csi', ''),
                        'imageRegistryEmail':    sas.get('image-registry', ''),
                    },
                },
            },
        },
        'clusterID': str(uuid.uuid4()),
    },
    'kind': 'Cluster',
}

# Optionally include signing key
if include_key and os.path.exists(key_path):
    with open(key_path) as f:
        payload['spec']['signingKey'] = f.read().strip()

with open(output_file, 'w') as f:
    json.dump(payload, f, indent=2)
    f.write('\n')

print(f'Payload written to: {output_file}')
print(f'  Cluster  : {cluster_name}')
print(f'  Infra ID : {infra_id}')
print(f'  Project  : {project_id}')
print(f'  Region   : {region}')
print(f'  Network  : {network}')
print(f'  Subnet   : {subnet}')
print(f'  ClusterID: {payload[\"spec\"][\"clusterID\"]}')
if include_key:
    print(f'  SigningKey: included')
" \
  "$CLUSTER_NAME" \
  "$INFRA_ID" \
  "$ENDPOINT_ACCESS" \
  "$NETWORK_OVERRIDE" \
  "$SUBNET_OVERRIDE" \
  "$INCLUDE_SIGNING_KEY" \
  "$OUTPUT_FILE" \
  "$IAM_CONFIG" \
  "$INFRA_CONFIG" \
  "$SIGNING_KEY_B64" \
  "${EXTRA_LABELS[@]+"${EXTRA_LABELS[@]}"}"
