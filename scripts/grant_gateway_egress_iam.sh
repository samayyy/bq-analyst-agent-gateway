#!/usr/bin/env bash
# Grants the agent's Agent Identity roles/iap.egressor REGISTRY-WIDE so the
# Agent Gateway (agent-to-anywhere) lets its egress traffic through.
#
# Agent Gateway egress is default-deny: IAP authorizes the SOURCE agent's
# principal against the DESTINATION Agent Registry resources. The pragmatic
# onboarding grant is registry-wide; tighten later per MCP server/endpoint
# (see AGENT_GATEWAY.md "Tightening").
#
# Requires gcloud >= 570.0.0 (the IAP agent-registry flags shipped 2026-05-27).
# Must re-run after every FRESH agent create (new engine ID = new principal).
#
# Usage: ./scripts/grant_gateway_egress_iam.sh <PROJECT_ID> <REGION> <AGENT_ENGINE_ID>

set -euo pipefail

if [[ $# -ne 3 ]]; then
  echo "Usage: $0 <PROJECT_ID> <REGION> <AGENT_ENGINE_ID>" >&2
  exit 1
fi

PROJECT_ID="$1"
REGION="$2"
AGENT_ENGINE_ID="$3"

PROJECT_NUMBER=$(gcloud projects describe "${PROJECT_ID}" --format='value(projectNumber)')
ORG_ID=$(gcloud projects get-ancestors "${PROJECT_ID}" --format='csv[no-heading](id,type)' \
  | awk -F, '$2=="organization"{print $1}')
if [[ -n "${ORG_ID}" ]]; then
  TRUST_DOMAIN="agents.global.org-${ORG_ID}.system.id.goog"
else
  TRUST_DOMAIN="agents.global.project-${PROJECT_NUMBER}.system.id.goog"
fi
PRINCIPAL="principal://${TRUST_DOMAIN}/resources/aiplatform/projects/${PROJECT_NUMBER}/locations/${REGION}/reasoningEngines/${AGENT_ENGINE_ID}"

echo "Granting roles/iap.egressor (registry-wide) to:"
echo "  ${PRINCIPAL}"

TMP_DIR=$(mktemp -d)
trap 'rm -rf "${TMP_DIR}"' EXIT

# set-iam-policy REPLACES the whole policy: fetch, merge, then set.
gcloud beta iap web get-iam-policy \
  --project="${PROJECT_ID}" \
  --resource-type=agent-registry \
  --region="${REGION}" \
  --format=json > "${TMP_DIR}/policy.json"

PRINCIPAL="${PRINCIPAL}" python3 - "${TMP_DIR}/policy.json" <<'EOF'
import json
import os
import sys

path = sys.argv[1]
principal = os.environ["PRINCIPAL"]
with open(path) as f:
    policy = json.load(f) or {}

bindings = policy.setdefault("bindings", [])
binding = next((b for b in bindings if b.get("role") == "roles/iap.egressor"
                and not b.get("condition")), None)
if binding is None:
    binding = {"role": "roles/iap.egressor", "members": []}
    bindings.append(binding)
if principal in binding["members"]:
    print("Binding already present - nothing to do.")
else:
    binding["members"].append(principal)
    print("Added member to roles/iap.egressor binding.")

with open(path, "w") as f:
    json.dump(policy, f, indent=2)
EOF

gcloud beta iap web set-iam-policy "${TMP_DIR}/policy.json" \
  --project="${PROJECT_ID}" \
  --resource-type=agent-registry \
  --region="${REGION}" \
  --format="value(etag)"

echo
echo "Done. IAM changes can take 1-2 minutes to propagate."
