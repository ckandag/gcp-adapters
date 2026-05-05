#!/bin/bash
# End-to-end: setup infra, generate payload, create cluster.
#
# Usage:
#   ./e2e-create-cluster.sh <cluster-name> <project-id> [options]
#
# Options:
#   --region <region>         GCP region (default: us-central1)
#   --vpc-cidr <cidr>         Subnet CIDR (default: 10.0.0.0/24)
#   --network <name>          Override VPC network name
#   --subnet <name>           Override subnet name
#   --endpoint-access <mode>  Private or PublicAndPrivate (default: PublicAndPrivate)
#   --signing-key             Include signing key in payload
#   --test-label <value>      Set the test label
#
# Example:
#   ./e2e-create-cluster.sh hctest20 ck-hcp-test
#    

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

CLUSTER_NAME="${1:?Usage: $0 <cluster-name> <project-id> [options]}"
PROJECT_ID="${2:?Usage: $0 <cluster-name> <project-id> [options]}"
shift 2

# Split args: region/vpc-cidr go to setup-infra, the rest to gen-payload
REGION="us-central1"
VPC_CIDR="10.0.0.0/24"
GEN_ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --region)           REGION="$2"; shift 2 ;;
    --vpc-cidr)         VPC_CIDR="$2"; shift 2 ;;
    --network|--subnet|--endpoint-access|--test-label)
                        GEN_ARGS+=("$1" "$2"); shift 2 ;;
    --signing-key)      GEN_ARGS+=("$1"); shift ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

# Step 1: Setup infrastructure
echo "=== Step 1/3: Setup Infrastructure ==="
"${SCRIPT_DIR}/setup-infra.sh" "$CLUSTER_NAME" "$PROJECT_ID" "$REGION" "$VPC_CIDR"
echo

# Step 2: Generate payload
echo "=== Step 2/3: Generate Payload ==="
"${SCRIPT_DIR}/gen-payload.sh" "$CLUSTER_NAME" "${GEN_ARGS[@]+"${GEN_ARGS[@]}"}"
echo

# Step 3: Create cluster
echo "=== Step 3/3: Create Cluster ==="
"${SCRIPT_DIR}/create-cluster.sh" "${SCRIPT_DIR}/${CLUSTER_NAME}-payload.json"
