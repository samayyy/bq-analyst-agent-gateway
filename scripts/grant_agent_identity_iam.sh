#!/usr/bin/env bash
# Grants the deployed agent's Agent Identity the roles it needs.
#
# The Agent Identity principal embeds the reasoningEngines resource ID, so this
# can only run AFTER `adk deploy agent_engine` has created the agent.
# Project number and organization ID are derived automatically; orgless
# projects get the project-scoped trust domain.
#
# Usage: ./scripts/grant_agent_identity_iam.sh <PROJECT_ID> <LOCATION> <AGENT_ENGINE_ID>
# Example: ./scripts/grant_agent_identity_iam.sh my-project asia-south1 1234567890123456789

set -euo pipefail

if [[ $# -ne 3 ]]; then
  echo "Usage: $0 <PROJECT_ID> <LOCATION> <AGENT_ENGINE_ID>" >&2
  exit 1
fi

PROJECT_ID="$1"
LOCATION="$2"
AGENT_ENGINE_ID="$3"

PROJECT_NUMBER=$(gcloud projects describe "${PROJECT_ID}" --format='value(projectNumber)')

# Trust domain: org-scoped when the project belongs to an organization,
# project-scoped otherwise.
ORG_ID=$(gcloud projects get-ancestors "${PROJECT_ID}" --format='csv[no-heading](id,type)' \
  | awk -F, '$2=="organization"{print $1}')
if [[ -n "${ORG_ID}" ]]; then
  TRUST_DOMAIN="agents.global.org-${ORG_ID}.system.id.goog"
else
  TRUST_DOMAIN="agents.global.project-${PROJECT_NUMBER}.system.id.goog"
fi

PRINCIPAL="principal://${TRUST_DOMAIN}/resources/aiplatform/projects/${PROJECT_NUMBER}/locations/${LOCATION}/reasoningEngines/${AGENT_ENGINE_ID}"

echo "Project number: ${PROJECT_NUMBER}"
echo "Trust domain:   ${TRUST_DOMAIN}"
echo "Granting roles to agent identity:"
echo "  ${PRINCIPAL}"
echo

# mcp.toolUser     -> call managed MCP server tools (mcp.tools.call)
# bigquery.jobUser -> run query jobs
# bigquery.dataViewer -> read table data/metadata
# aiplatform.user  -> call Gemini on the Vertex global endpoint
# serviceusage.serviceUsageConsumer -> bill/quota via x-goog-user-project
for ROLE in \
  roles/mcp.toolUser \
  roles/bigquery.jobUser \
  roles/bigquery.dataViewer \
  roles/aiplatform.user \
  roles/serviceusage.serviceUsageConsumer; do
  echo ">> ${ROLE}"
  gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
    --member="${PRINCIPAL}" \
    --role="${ROLE}" \
    --condition=None \
    --format="value(etag)"
done

echo
echo "Done. IAM changes can take 1-2 minutes to propagate."
