#!/usr/bin/env bash
# Registers the Google API destinations a gateway-bound Agent Engine agent
# needs in the regional Agent Registry — each with ALL FIVE hostname
# permutations, exactly like the official Agent Gateway demo
# (GoogleCloudPlatform/cloud-networking-solutions/demos/agent-gateway):
#   base            https://SVC.googleapis.com
#   mTLS            https://SVC.mtls.googleapis.com
#   locational      https://REGION-SVC.googleapis.com
#   locational mTLS https://REGION-SVC.mtls.googleapis.com
#   regional REP    https://SVC.REGION.rep.googleapis.com
#
# The gateway matches hostnames EXACTLY; the SDK may dial any permutation
# depending on version/region/mTLS state. Idempotent: existing entries are
# skipped.
#
# Usage: ./scripts/register_gateway_endpoints.sh <PROJECT_ID> <REGION>

set -uo pipefail

if [[ $# -ne 2 ]]; then
  echo "Usage: $0 <PROJECT_ID> <REGION>" >&2
  exit 1
fi

PROJECT_ID="$1"
LOCATION="$2"

# Demo's bootstrap list + bigquery (managed MCP + API) + www (tokeninfo).
GOOGLE_APIS=(
  aiplatform
  bigquery
  cloudresourcemanager
  global-discoveryengine
  discoveryengine
  logging
  monitoring
  oauth2
  telemetry
  trace
  cloudtrace
  agentregistry
  iap
  iamcredentials
  www
)

reg_svc() {
  local svc_id="$1" display_name="$2" url="$3"
  if gcloud alpha agent-registry services describe "$svc_id" \
      --project="$PROJECT_ID" --location="$LOCATION" >/dev/null 2>&1; then
    echo "  exists: $svc_id"
    return 0
  fi
  echo "  registering: $svc_id -> $url"
  gcloud alpha agent-registry services create "$svc_id" \
    --project="$PROJECT_ID" \
    --location="$LOCATION" \
    --display-name="$display_name" \
    --endpoint-spec-type=no-spec \
    --interfaces="url=$url,protocolBinding=JSONRPC" \
    || echo "  WARN: failed to register $svc_id (see error above)"
}

for ID in "${GOOGLE_APIS[@]}"; do
  echo ">> $ID"
  reg_svc "${ID}"                       "${ID}"                  "https://${ID}.googleapis.com"
  reg_svc "${ID}-mtls"                  "${ID} mTLS"             "https://${ID}.mtls.googleapis.com"
  reg_svc "${LOCATION}-${ID}"           "${ID} locational"       "https://${LOCATION}-${ID}.googleapis.com"
  reg_svc "${LOCATION}-${ID}-mtls"      "${ID} locational mTLS"  "https://${LOCATION}-${ID}.mtls.googleapis.com"
  reg_svc "${ID}-${LOCATION}-rep"       "${ID} regional REP"     "https://${ID}.${LOCATION}.rep.googleapis.com"
done

echo
echo "Done. Verify with:"
echo "  gcloud alpha agent-registry endpoints list --project=$PROJECT_ID --location=$LOCATION"
echo "Remember: registry entries are covered by a REGISTRY-WIDE roles/iap.egressor"
echo "grant (scripts/grant_gateway_egress_iam.sh) automatically."
