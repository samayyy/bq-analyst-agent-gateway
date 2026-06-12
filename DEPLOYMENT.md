# Deploying this agent in a new GCP project

Step-by-step runbook for deploying the BigQuery Analyst agent into any project.
Everything below was validated end-to-end on a real deployment (June 2026,
google-adk 2.2.0). Run all commands from the repo root.

## 0. Set your variables

```bash
export PROJECT_ID="YOUR_PROJECT_ID"        # alphanumeric ID, not the number
export REGION="asia-south1"                # must support Agent Engine (see note)
export DISPLAY_NAME="BigQuery Analyst"
```

Agent Engine supported regions include: `us-central1`, `us-east1`, `us-east4`,
`us-west1`, `europe-west1..4/6/8`, `europe-southwest1`, `asia-south1`,
`asia-southeast1`, `asia-east1/2`, `asia-northeast1/3`, `me-west1`, and more.
If you plan to use **Agent Gateway**, deploy the agent in the **same region as
the gateway** (Agent Gateway is not available in every Agent Engine region).

Prerequisites: `gcloud` CLI (recent), Python **3.10–3.14** (3.12 recommended),
and permission to administer the project (or at minimum the deployer roles in
step 3).

## 1. Authenticate

```bash
gcloud auth login
gcloud config set project "$PROJECT_ID"
gcloud auth application-default login
gcloud auth application-default set-quota-project "$PROJECT_ID"
```

## 2. Enable the required APIs

```bash
gcloud services enable \
  aiplatform.googleapis.com \
  bigquery.googleapis.com \
  storage.googleapis.com \
  logging.googleapis.com \
  monitoring.googleapis.com \
  cloudtrace.googleapis.com \
  telemetry.googleapis.com \
  cloudresourcemanager.googleapis.com \
  --project="$PROJECT_ID"
```

Notes:
- Enabling the BigQuery API automatically enables the managed **BigQuery MCP
  server** at `https://bigquery.googleapis.com/mcp` (GA) — no separate step.
- Pre-provision the Agent Engine service agent (idempotent, avoids a race on
  first deploy):

```bash
gcloud beta services identity create \
  --service=aiplatform.googleapis.com --project="$PROJECT_ID"
```

## 3. Deployer IAM (the human running the deploy)

Project Owner covers everything. Otherwise grant yourself:

| Role | Why |
|---|---|
| `roles/aiplatform.user` | create/manage Agent Engine deployments |
| `roles/serviceusage.serviceUsageAdmin` | enable APIs (step 2 only) |
| `roles/resourcemanager.projectIamAdmin` | run the IAM grant script (step 7) |
| `roles/mcp.toolUser` + `roles/bigquery.jobUser` + `roles/bigquery.dataViewer` | only needed to run the LOCAL smoke test with your own ADC |

## 4. Python environment

```bash
python3.12 -m venv .venv          # or: uv venv --python 3.12 .venv
source .venv/bin/activate
pip install -r bq_analyst/requirements.txt
```

## 5. Configure the agent

```bash
cp bq_analyst/.env.example bq_analyst/.env
```

Edit `bq_analyst/.env`:
- `GOOGLE_CLOUD_PROJECT` / `BQ_PROJECT_ID` → your `$PROJECT_ID`
- `GOOGLE_CLOUD_LOCATION` → your `$REGION`
- Leave `GOOGLE_API_PREVENT_AGENT_TOKEN_SHARING_FOR_GCP_SERVICES=false` in
  place — without it, every MCP call from the deployed agent fails with 401
  (Agent Identity tokens are certificate-bound and ADK's MCP transport can't
  present the binding yet; see README "Why GOOGLE_API_PREVENT_..." section).
- The model `gemini-3.1-flash-lite` is served from the Vertex **global**
  endpoint only; the code handles that — no region coupling.

## 6. Optional: local smoke test before deploying

Runs the agent in-process with YOUR credentials (needs the local-test roles
from step 3, and at least one dataset in the project):

```bash
python scripts/local_smoke_test.py
```

## 7. Deploy to Agent Engine

```bash
adk deploy agent_engine \
  --project="$PROJECT_ID" \
  --region="$REGION" \
  --display_name="$DISPLAY_NAME" \
  bq_analyst
```

- **Success signal**: the line `Deployed to Agent Platform:
  projects/.../reasoningEngines/<ID>` — the CLI exits 0 even on failure, so
  look for that line, not the exit code.
- **Record the numeric `AGENT_ENGINE_ID`** from the resource name.
- The deploy automatically picks up `bq_analyst/.agent_engine_config.json`,
  which sets `identity_type: AGENT_IDENTITY` — the agent gets its own
  first-class IAM principal (not a shared service account).
- **Redeploys**: always add `--agent_engine_id=$AGENT_ENGINE_ID`, otherwise a
  duplicate engine (with a different identity) is created.

```bash
export AGENT_ENGINE_ID="PASTE_THE_NUMERIC_ID"
```

## 8. Grant the agent's identity its roles

The Agent Identity principal embeds the engine ID, so this must run **after**
deploy. The script auto-derives the project number and the trust domain (org
vs. orgless):

```bash
./scripts/grant_agent_identity_iam.sh "$PROJECT_ID" "$REGION" "$AGENT_ENGINE_ID"
```

Roles granted (all project-scoped, least-privilege, read-only data access):
`roles/mcp.toolUser`, `roles/bigquery.jobUser`, `roles/bigquery.dataViewer`,
`roles/aiplatform.user`, `roles/serviceusage.serviceUsageConsumer`.

Wait 1–2 minutes for IAM propagation before testing.

## 9. Test the deployed agent

```bash
PROJECT_ID="$PROJECT_ID" LOCATION="$REGION" \
  python scripts/remote_smoke_test.py "$AGENT_ENGINE_ID"

# or ask your own question:
PROJECT_ID="$PROJECT_ID" LOCATION="$REGION" \
  python scripts/remote_smoke_test.py "$AGENT_ENGINE_ID" "What datasets do we have?"
```

Console playground:
`https://console.cloud.google.com/vertex-ai/agents/agent-engines/locations/$REGION/agent-engines/$AGENT_ENGINE_ID/playground?project=$PROJECT_ID`

The agent also has an `auth_diagnostics` tool — in the playground, ask
*"run auth diagnostics"* and it reports token-binding state, certificate
presence, token scopes, and a direct MCP-call result from inside the runtime.

## 10. Verify the identity (optional)

```bash
TOKEN=$(gcloud auth print-access-token)
curl -s "https://$REGION-aiplatform.googleapis.com/v1beta1/projects/$PROJECT_ID/locations/$REGION/reasoningEngines/$AGENT_ENGINE_ID" \
  -H "Authorization: Bearer $TOKEN" | grep -E "identityType|effectiveIdentity"
```

Expect `"identityType": "AGENT_IDENTITY"` and an `effectiveIdentity` of the
form `agents.global.org-<ORG>.system.id.goog/resources/aiplatform/...`.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| Tool calls fail, agent says it can't reach BigQuery; logs show `401 Unauthorized` on `https://bigquery.googleapis.com/mcp` | Certificate-bound token issue — confirm `GOOGLE_API_PREVENT_AGENT_TOKEN_SHARING_FOR_GCP_SERVICES=false` was in `.env` at deploy time (it ships as a runtime env var). Redeploy if it was missing. |
| `403 PERMISSION_DENIED` on MCP calls | IAM not yet propagated (wait 2 min) or step 8 skipped / run with wrong engine ID. |
| Model errors `404 Publisher Model ... not found` | The model is global-endpoint-only; this repo's `GlobalGemini` class handles it. If you changed `MODEL_NAME`, verify availability: the model must exist on `location=global` or your region. |
| Model errors `429 RESOURCE_EXHAUSTED` | Preview-model shared capacity; the agent retries automatically (4 attempts, backoff). Persistent 429s → switch `MODEL_NAME` to `gemini-2.5-flash`. |
| Deploy "succeeds" but nothing was created | The CLI swallows errors — scroll up for the actual exception; check you ran it from the repo root with the venv active. |
| The real error detail for any runtime failure | `gcloud logging read 'resource.type="aiplatform.googleapis.com/ReasoningEngine" AND resource.labels.reasoning_engine_id="'$AGENT_ENGINE_ID'"' --project=$PROJECT_ID --limit=50 --freshness=15m` |

## Costs

Agent Engine bills vCPU-hours/GiB-hours after a monthly free tier (50 vCPU-h +
100 GiB-h); idle time is not billed. Sessions cost $0.25/1,000 stored events.
Gemini tokens and BigQuery queries bill separately at standard rates. MCP
queries carry job label `goog-mcp-server: true` for cost attribution.
