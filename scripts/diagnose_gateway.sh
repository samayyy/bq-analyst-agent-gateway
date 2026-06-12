#!/usr/bin/env bash
# One-shot Agent Gateway diagnostics. Collects every signal needed to pinpoint
# why a gateway-bound agent's egress fails, into a single report file.
#
# Usage: ./scripts/diagnose_gateway.sh <PROJECT_ID> <REGION> <AGENT_ENGINE_ID> <GATEWAY_ID>
# Then share the printed report file.

set -uo pipefail

if [[ $# -ne 4 ]]; then
  echo "Usage: $0 <PROJECT_ID> <REGION> <AGENT_ENGINE_ID> <GATEWAY_ID>" >&2
  exit 1
fi

PROJECT_ID="$1"; REGION="$2"; ENGINE_ID="$3"; GATEWAY_ID="$4"
TOKEN=$(gcloud auth print-access-token)
PROJECT_NUMBER=$(gcloud projects describe "${PROJECT_ID}" --format='value(projectNumber)')
OUT="/tmp/gateway_diagnostics_$(date +%s).txt"

section() { echo -e "\n========== $1 ==========" | tee -a "$OUT"; }
run() { echo "\$ $*" >> "$OUT"; "$@" >> "$OUT" 2>&1; }

echo "Writing report to $OUT"
echo "diagnostics run: $(date -u) project=$PROJECT_ID region=$REGION engine=$ENGINE_ID gateway=$GATEWAY_ID" > "$OUT"

section "1. ENGINE: identity, env vars, gateway binding"
curl -s -H "Authorization: Bearer $TOKEN" \
  "https://${REGION}-aiplatform.googleapis.com/v1beta1/projects/${PROJECT_ID}/locations/${REGION}/reasoningEngines/${ENGINE_ID}" \
  | python3 -c "
import sys, json
d = json.load(sys.stdin)
spec = d.get('spec', {})
dep = spec.get('deploymentSpec', {})
print('updateTime:', d.get('updateTime'))
print('identityType:', spec.get('identityType'))
print('effectiveIdentity:', spec.get('effectiveIdentity'))
print('agentGatewayConfig:', json.dumps(dep.get('agentGatewayConfig')))
print('env:')
for e in dep.get('env', []):
    print('  ', e.get('name'), '=', repr(e.get('value')))
" >> "$OUT" 2>&1

section "2. GATEWAY resource"
run gcloud alpha network-services agent-gateways describe "$GATEWAY_ID" --location="$REGION" --project="$PROJECT_ID"

section "3. AUTHZ POLICIES targeting the gateway (MUST include one for IAP; empty = known-issue #4 = everything denied)"
curl -s -H "Authorization: Bearer $TOKEN" \
  "https://networksecurity.googleapis.com/v1alpha1/projects/${PROJECT_ID}/locations/${REGION}/authzPolicies" >> "$OUT" 2>&1

section "4. AUTHZ EXTENSIONS (IAP / Model Armor callouts; check iamEnforcementMode DRY_RUN vs absent=ENFORCE)"
curl -s -H "Authorization: Bearer $TOKEN" \
  "https://serviceextensions.googleapis.com/v1alpha1/projects/${PROJECT_ID}/locations/${REGION}/authzExtensions" >> "$OUT" 2>&1

section "5. REGISTRY: registered endpoints/mcp-servers mentioning our critical hostnames"
{
  gcloud alpha agent-registry endpoints list --project="$PROJECT_ID" --location="$REGION" \
    --format="value(name, interfaces.url)" 2>&1 | grep -iE "cloudresourcemanager|aiplatform|bigquery|oauth2|telemetry|logging|monitoring|iamcredentials|iap|agentregistry" \
    || echo "(no matching endpoints — or command failed, see below)"
  gcloud alpha agent-registry mcp-servers list --project="$PROJECT_ID" --location="$REGION" \
    --format="value(name, interfaces.url)" 2>&1
} >> "$OUT" 2>&1

section "6. REGISTRY-WIDE IAP IAM POLICY (must contain roles/iap.egressor for the agent principal)"
echo "expected member: principal://agents.global.org-<ORG>.system.id.goog/resources/aiplatform/projects/${PROJECT_NUMBER}/locations/${REGION}/reasoningEngines/${ENGINE_ID}" >> "$OUT"
curl -s -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"options": {"requestedPolicyVersion": 3}}' \
  -X POST "https://iap.googleapis.com/v1/projects/${PROJECT_NUMBER}/locations/${REGION}/iap_web/agentRegistry:getIamPolicy" >> "$OUT" 2>&1

section "7. IAP AUDIT LOG: egress allow/deny decisions, last 2h (EMPTY here + denials elsewhere = IAP never consulted = missing authz policy)"
run gcloud logging read "protoPayload.serviceName=\"iap.googleapis.com\" AND protoPayload.authorizationInfo.permission=\"iap.webServiceVersions.egressViaIAP\"" \
  --project="$PROJECT_ID" --limit=25 --freshness=2h \
  --format="json(timestamp, protoPayload.authorizationInfo, protoPayload.authenticationInfo.principalSubject, labels)"

section "8. GATEWAY PROXY LOG, non-CONNECT entries, last 2h (inner request decisions: status, requestUrl, authz result)"
run gcloud logging read "jsonPayload.@type=\"type.googleapis.com/google.cloud.loadbalancing.type.LoadBalancerLogEntry\" AND resource.labels.gateway_type=\"SECURE_WEB_GATEWAY\" AND -httpRequest.requestMethod=\"CONNECT\"" \
  --project="$PROJECT_ID" --limit=25 --freshness=2h \
  --format="json(timestamp, httpRequest.status, httpRequest.requestUrl, httpRequest.requestMethod, jsonPayload.authzPolicyInfo, jsonPayload.enforcedGatewaySecurityPolicy)"

section "9. RUNTIME ERRORS, last 2h"
run gcloud logging read "resource.type=\"aiplatform.googleapis.com/ReasoningEngine\" AND resource.labels.reasoning_engine_id=\"${ENGINE_ID}\" AND severity>=ERROR" \
  --project="$PROJECT_ID" --limit=10 --freshness=2h --format="value(timestamp, textPayload)"

echo
echo "DONE. Report: $OUT"
echo "Share the whole file."
