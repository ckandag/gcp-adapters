#!/bin/bash
# Create a test cluster via the Hyperfleet API
# Usage: ./create-cluster.sh [payload.json]

API_URL="${HYPERFLEET_API_URL:-http://localhost:8000}"
PAYLOAD_FILE="${1:-$(dirname "$0")/hc-test1-payload.json}"

# Start port-forward if not already running
if ! curl -s --connect-timeout 1 "${API_URL}/healthcheck" > /dev/null 2>&1; then
  echo "Starting port-forward to hyperfleet-api..."
  kubectl port-forward svc/hyperfleet-api 8000:8000 -n hyperfleet &
  sleep 2
fi

curl -s -X POST "${API_URL}/api/hyperfleet/v1/clusters" \
  -H "Content-Type: application/json" \
  -d @"${PAYLOAD_FILE}" | python3 -m json.tool
