#!/bin/bash
# Provision GCP infrastructure for a hosted cluster.
#
# Steps:
#   1. Generate RSA 4096-bit keypair (PKCS#1) + JWKS with kid=SHA256(DER pub key)
#   2. Run 'hypershift create iam gcp' to create WIF pool, provider, and service accounts
#   3. Run 'hypershift create infra gcp' to create VPC, subnet, router, NAT
#
# Outputs (saved to ./output/<infra-id>/):
#   - signing-key.pem          PKCS#1 private key
#   - signing-key-base64.txt   Base64-encoded PEM (for HyperFleet API spec.signingKey)
#   - jwks.json                JWKS public key document
#   - iam-config.json          IAM/WIF configuration from hypershift
#   - infra-config.json        Network configuration from hypershift
#
# Usage:
#   ./setup-infra.sh <infra-id> <project-id> [region] [vpc-cidr]
#
# Example:
#   ./setup-infra.sh hctest20 dev-mgt-us-c1-ckandag910f us-central1

set -euo pipefail

# ---------------------------------------------------------------------------
# Args
# ---------------------------------------------------------------------------
INFRA_ID="${1:?Usage: $0 <infra-id> <project-id> [region] [vpc-cidr]}"
PROJECT_ID="${2:?Usage: $0 <infra-id> <project-id> [region] [vpc-cidr]}"
REGION="${3:-us-central1}"
VPC_CIDR="${4:-10.0.0.0/24}"

HYPERSHIFT_BIN="${HYPERSHIFT_BINARY:-$(command -v hypershift 2>/dev/null || true)}"
if [[ -z "$HYPERSHIFT_BIN" ]]; then
  echo "ERROR: hypershift CLI not found. Install it or set HYPERSHIFT_BINARY."
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUT_DIR="${SCRIPT_DIR}/output/${INFRA_ID}"
mkdir -p "$OUT_DIR"

echo "============================================"
echo "  HyperFleet Infrastructure Setup"
echo "============================================"
echo "  Infra ID  : ${INFRA_ID}"
echo "  Project   : ${PROJECT_ID}"
echo "  Region    : ${REGION}"
echo "  VPC CIDR  : ${VPC_CIDR}"
echo "  Output    : ${OUT_DIR}"
echo "============================================"
echo

# ---------------------------------------------------------------------------
# Step 1: Generate RSA 4096-bit keypair + JWKS (using openssl + python3)
# ---------------------------------------------------------------------------
echo ">>> Step 1: Generate RSA keypair and JWKS"

# Generate 4096-bit RSA key in PKCS#1 format
openssl genrsa 4096 2>/dev/null | openssl rsa -traditional -out "${OUT_DIR}/signing-key.pem" 2>/dev/null

# Extract public key
openssl rsa -in "${OUT_DIR}/signing-key.pem" -pubout -out "${OUT_DIR}/sa-signer.pub" 2>/dev/null

# Base64-encode the PEM (for HyperFleet API spec.signingKey)
base64 -i "${OUT_DIR}/signing-key.pem" | tr -d '\n' > "${OUT_DIR}/signing-key-base64.txt"

# Generate JWKS from public key (uses only python3 stdlib + openssl)
python3 -c "
import json, base64, hashlib, subprocess, os, sys

out_dir = sys.argv[1]
pub_path = os.path.join(out_dir, 'sa-signer.pub')

# Parse modulus and exponent from openssl text output
text = subprocess.run(
    ['openssl', 'rsa', '-pubin', '-in', pub_path, '-text', '-noout'],
    capture_output=True, text=True, check=True).stdout
lines = text.splitlines()

mod_lines, in_mod, exp_hex = [], False, ''
for line in lines:
    if 'Modulus:' in line:
        in_mod = True; continue
    if 'Exponent:' in line:
        exp_hex = line.split('(')[1].rstrip(')') if '(' in line else ''
        in_mod = False; continue
    if in_mod:
        mod_lines.append(line.strip().replace(':', ''))

mod_bytes = bytes.fromhex(''.join(mod_lines))
if mod_bytes[0:1] == b'\x00':
    mod_bytes = mod_bytes[1:]

exp_int = int(exp_hex, 16)
exp_bytes = exp_int.to_bytes((exp_int.bit_length() + 7) // 8, 'big')

# kid = SHA256(DER-encoded public key)
der = subprocess.run(
    ['openssl', 'rsa', '-pubin', '-in', pub_path, '-outform', 'DER'],
    capture_output=True, check=True).stdout
kid = base64.urlsafe_b64encode(hashlib.sha256(der).digest()).decode().rstrip('=')

def b64url(b):
    return base64.urlsafe_b64encode(b).decode().rstrip('=')

jwks = {'keys': [{
    'use': 'sig', 'kty': 'RSA', 'kid': kid, 'alg': 'RS256',
    'n': b64url(mod_bytes), 'e': b64url(exp_bytes),
}]}

with open(os.path.join(out_dir, 'jwks.json'), 'w') as f:
    json.dump(jwks, f, indent=2)

print(f'  Key format : PKCS#1 (BEGIN RSA PRIVATE KEY)')
print(f'  Key size   : 4096 bits')
print(f'  kid        : {kid[:16]}...')
print(f'  Saved      : signing-key.pem, signing-key-base64.txt, jwks.json')
" "$OUT_DIR"

# Cleanup temp public key
rm -f "${OUT_DIR}/sa-signer.pub"

echo

# ---------------------------------------------------------------------------
# Step 2: Setup IAM (WIF) via hypershift
# ---------------------------------------------------------------------------
echo ">>> Step 2: Setup IAM infrastructure (WIF)"
echo "  Running: $HYPERSHIFT_BIN create iam gcp"

OIDC_ISSUER_URL="https://hypershift-${INFRA_ID}-oidc"

"$HYPERSHIFT_BIN" create iam gcp \
  --infra-id "$INFRA_ID" \
  --project-id "$PROJECT_ID" \
  --oidc-jwks-file "${OUT_DIR}/jwks.json" \
  --oidc-issuer-url "$OIDC_ISSUER_URL" \
  > "${OUT_DIR}/iam-config.json"

echo "  Saved: iam-config.json"
echo "  IAM config:"
python3 -m json.tool "${OUT_DIR}/iam-config.json"
echo

# ---------------------------------------------------------------------------
# Step 3: Setup Network via hypershift
# ---------------------------------------------------------------------------
echo ">>> Step 3: Setup network infrastructure"
echo "  Running: $HYPERSHIFT_BIN create infra gcp"

"$HYPERSHIFT_BIN" create infra gcp \
  --infra-id "$INFRA_ID" \
  --project-id "$PROJECT_ID" \
  --region "$REGION" \
  --vpc-cidr "$VPC_CIDR" \
  > "${OUT_DIR}/infra-config.json"

echo "  Saved: infra-config.json"
echo "  Infra config:"
python3 -m json.tool "${OUT_DIR}/infra-config.json"
echo

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo "============================================"
echo "  Infrastructure setup complete!"
echo "============================================"
echo
echo "Output files in ${OUT_DIR}/:"
ls -1 "${OUT_DIR}/"
echo
echo "Next steps:"
echo "  1. Use the signing key in your cluster payload:"
echo "     spec.signingKey = \$(cat ${OUT_DIR}/signing-key-base64.txt)"
echo
echo "  2. Use IAM config values for workloadIdentity in your payload:"
echo "     cat ${OUT_DIR}/iam-config.json"
echo
echo "  3. Use infra config for network values in your payload:"
echo "     cat ${OUT_DIR}/infra-config.json"
echo
echo "  4. To tear down later:"
echo "     $HYPERSHIFT_BIN destroy infra gcp --infra-id $INFRA_ID --project-id $PROJECT_ID --region $REGION"
echo "     $HYPERSHIFT_BIN destroy iam gcp --infra-id $INFRA_ID --project-id $PROJECT_ID"
