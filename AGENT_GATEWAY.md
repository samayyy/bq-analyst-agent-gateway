# Routing this agent's MCP traffic through Agent Gateway (Agent-to-Anywhere)

This branch binds the agent to a Google Cloud **Agent Gateway** (Private
Preview) so all of its outbound MCP/tool traffic is governed by the gateway:
default-deny egress, per-tool IAM authorization (IAP for Agents), full traffic
logging, and optional Model Armor screening.

Follow [DEPLOYMENT.md](DEPLOYMENT.md) first for the baseline (APIs, IAM,
deploy basics) — this document covers only what Agent Gateway adds.

## How it works (so the steps make sense)

- **Agent-to-Anywhere is a transparent egress proxy, not a URL.** The agent
  code does NOT change — `McpToolset` keeps calling
  `https://bigquery.googleapis.com/mcp`. The Agent Engine runtime routes all
  egress through the gateway once the deployment is **bound** to it via
  `agent_gateway_config` (already added to `bq_analyst/.agent_engine_config.json`
  on this branch — fill in the placeholder).
- Security chain: agent —mTLS→ gateway; the gateway terminates mTLS, IAP
  checks the agent's IAM (`roles/iap.egressor`) against the **destination's**
  Agent Registry entry, generates a DPoP proof, and forwards to the target.
  All of this is platform-handled — no DPoP/auth code in the agent.
- **Destinations** come from the regional **Agent Registry** referenced by the
  gateway. Anything not registered there is blocked by default.
- Agent, gateway, and registry must be in the **same project and same region**.
  The agent must run with **Agent Identity** (this repo already does).

## ⚠️ Read before deploying (preview constraints)

1. **Binding is irreversible** — you cannot unbind a Runtime agent from an
   Agent Gateway. Use a test project you can afford to constrain.
2. **All Agent Runtime agents in the same project+region must bind to the same
   egress gateway.** Additionally, a known preview issue reportedly allows only
   ONE actively-bonded ReasoningEngine per project (second bind fails with
   "Internal error encountered"). **Check for existing bonded agents first**
   (Phase 0) and confirm with your Google preview contact.
3. VPC Service Controls and SCC threat detection are **incompatible** with
   gateway-bound agents (preview).
4. Max 4 custom authorization policies per gateway; registry must be a real
   region (`us`/`eu` multi-regions unsupported).
5. Tooling floors: **gcloud ≥ 570.0.0** (`gcloud components update`),
   `google-cloud-aiplatform ≥ 1.148.1` in the deploy venv (this branch's
   requirements.txt enforces it).

## Variables

```bash
export PROJECT_ID="YOUR_PROJECT_ID"
export REGION="YOUR_REGION"             # must equal the gateway's region
export GATEWAY_ID="YOUR_GATEWAY_ID"     # existing agent-to-anywhere gateway
```

## Phase 0 — Inspect the existing gateway

```bash
# 0.1 Confirm mode, protocols, and registry binding
gcloud alpha network-services agent-gateways describe "$GATEWAY_ID" --location="$REGION"
gcloud alpha network-services agent-gateways export "$GATEWAY_ID" --location="$REGION"
```

Expect: `governedAccessPath: AGENT_TO_ANYWHERE`, `protocols:` including `MCP`,
and `registries:` containing
`//agentregistry.googleapis.com/projects/$PROJECT_ID/locations/$REGION`.

```bash
# 0.2 Any agent already bonded to a gateway in this project? (constraint #2)
TOKEN=$(gcloud auth print-access-token)
curl -s -H "Authorization: Bearer $TOKEN" \
  "https://$REGION-aiplatform.googleapis.com/v1beta1/projects/$PROJECT_ID/locations/$REGION/reasoningEngines" \
  | grep -iE "agentGatewayConfig|displayName" || echo "no engines / no bindings"

# 0.3 What authorization policies target the gateway? (IAP enforce vs dry-run,
#     Model Armor, tool allow-lists)
curl -s -H "Authorization: Bearer $TOKEN" \
  "https://networksecurity.googleapis.com/v1alpha1/projects/$PROJECT_ID/locations/$REGION/authzPolicies"
curl -s -H "Authorization: Bearer $TOKEN" \
  "https://networkservices.googleapis.com/v1alpha1/projects/$PROJECT_ID/locations/$REGION/authzExtensions"
```

Interpretation:
- An IAP extension (`service: iap.googleapis.com`) with metadata
  `iamEnforcementMode: "DRY_RUN"` = audit-only (denials logged, not blocked) —
  the safe onboarding mode. No `DRY_RUN` metadata = **enforcing**.
- If any policy has MCP **ALLOW `httpRules`**, they must include
  `baseProtocolMethodsOption: MATCH_BASE_PROTOCOL_METHODS` and allow the
  BigQuery tool names this agent uses (`list_dataset_ids`, `get_dataset_info`,
  `list_table_ids`, `get_table_info`, `execute_sql_readonly`) — otherwise the
  MCP session breaks silently at `initialize`.

## Phase 1 — Verify/register destinations in Agent Registry

```bash
# Google-managed MCP servers auto-register when their API is enabled — verify:
gcloud alpha agent-registry mcp-servers list --project="$PROJECT_ID" --location="$REGION"
gcloud alpha agent-registry services list --project="$PROJECT_ID" --location="$REGION" \
  --format="table(displayName, interfaces.url)"
```

If the BigQuery MCP server is **not** listed regionally, register it:

```bash
gcloud alpha agent-registry services create bigquery-mcp \
  --project="$PROJECT_ID" --location="$REGION" \
  --display-name="BigQuery MCP server" \
  --mcp-server-spec-type=no-spec \
  --interfaces=url=https://bigquery.googleapis.com/mcp,protocolBinding=JSONRPC
```

**Bootstrap endpoints** (required if IAP is ENFORCING; recommended anyway):
the agent's startup and model calls also egress through the gateway, so their
hostnames must be registered + authorized or the agent never starts. Register
each as an endpoint (hostname matching is EXACT):

Hostname matching is EXACT, and the runtime auto-switches Google SDK calls to
the `.mtls.googleapis.com` endpoint variants when Agent Identity certificates
are present — so register the **full permutation set** per service (this is
what Google's own gateway demo terraform does):

```bash
register() {
  gcloud alpha agent-registry services create "$1" \
    --project="$PROJECT_ID" --location="$REGION" \
    --display-name="Endpoint $2" \
    --endpoint-spec-type=no-spec \
    --interfaces="url=$2,protocolBinding=JSONRPC" || true
}
for SVC in aiplatform oauth2 iamcredentials logging monitoring telemetry \
           cloudtrace cloudresourcemanager iap www bigquery agentregistry; do
  register "ep-${SVC}"      "https://${SVC}.googleapis.com"
  register "ep-${SVC}-mtls" "https://${SVC}.mtls.googleapis.com"
done
# Regional variants the runtime dials (sessions API etc.):
for SVC in aiplatform agentregistry; do
  register "ep-${REGION}-${SVC}"      "https://${REGION}-${SVC}.googleapis.com"
  register "ep-${REGION}-${SVC}-mtls" "https://${REGION}-${SVC}.mtls.googleapis.com"
done
```

(`www` covers the `auth_diagnostics` tokeninfo call. If IAP is in DRY_RUN, you
can instead deploy first and read the would-be-denied hostnames from the logs
in Phase 4, then register exactly those. Either way, after deploying, iterate:
smoke test → gateway log names any still-blocked hostname → register it →
retry. The registry-wide `roles/iap.egressor` grant from Phase 3 covers newly
registered entries automatically.)

## Phase 2 — Deploy the agent with the gateway binding

**Pre-flight check** — the gateway config is validated client-side by the SDK
in your venv, so a stale venv fails with
`AgentEngineConfig ... Extra inputs are not permitted`. Verify first:

```bash
pip install --upgrade -r bq_analyst/requirements.txt
python -c "from vertexai import types; print('agent_gateway_config' in types.AgentEngineConfig.model_fields)"
# must print: True
```

If it prints `False` even after the install (common in Cloud Shell): a stale
`google-cloud-aiplatform` in `~/.local/lib/.../site-packages` is shadowing the
venv — usually because `PYTHONPATH` is exported in the shell profile
(PYTHONPATH entries beat venv site-packages). Diagnose with
`python -c "import vertexai; print(vertexai.__file__)"` (points at `~/.local`)
and `echo $PYTHONPATH`. Fix: `unset PYTHONPATH` (and remove the export from
`~/.bashrc`/`~/.profile`). Guaranteed fix either way — upgrade the `~/.local`
copies at the source so whichever copy wins supports the field:

```bash
deactivate
python3 -m pip install --user --upgrade \
  "google-adk[a2a,mcp]==2.2.0" "google-cloud-aiplatform[agent_engines]>=1.148.1"
source .venv/bin/activate
# re-run the True/False check before deploying
```

Edit `bq_analyst/.agent_engine_config.json` and replace the placeholder:

```json
{
  "identity_type": "AGENT_IDENTITY",
  "agent_gateway_config": {
    "agent_to_anywhere_config": {
      "agent_gateway": "projects/PROJECT_ID/locations/REGION/agentGateways/GATEWAY_ID"
    }
  }
}
```

Then deploy exactly as in DEPLOYMENT.md §7 (fresh deploy in this project; the
binding flows through the config file — the ADK CLI passes it through):

```bash
adk deploy agent_engine --project="$PROJECT_ID" --region="$REGION" \
  --display_name="BigQuery Analyst (gateway)" bq_analyst
export AGENT_ENGINE_ID="PASTE_NUMERIC_ID"
```

Verify the binding and the auto-registration:

```bash
curl -s -H "Authorization: Bearer $(gcloud auth print-access-token)" \
  "https://$REGION-aiplatform.googleapis.com/v1beta1/projects/$PROJECT_ID/locations/$REGION/reasoningEngines/$AGENT_ENGINE_ID" \
  | grep -E "agentGateway|identityType|effectiveIdentity"

# The agent self-registers in the regional Agent Registry:
gcloud alpha agent-registry agents list --project="$PROJECT_ID" --location="$REGION"
```

## Phase 3 — IAM (both scripts, every fresh deploy)

```bash
# Baseline data-plane roles (BigQuery, MCP, model calls):
./scripts/grant_agent_identity_iam.sh "$PROJECT_ID" "$REGION" "$AGENT_ENGINE_ID"

# Gateway egress authorization (roles/iap.egressor, registry-wide):
./scripts/grant_gateway_egress_iam.sh "$PROJECT_ID" "$REGION" "$AGENT_ENGINE_ID"
```

The principal embeds the engine ID — **re-run both after every fresh create**
(a redeploy with `--agent_engine_id` keeps the same principal).

### Tightening (optional, after it works)

Scope `roles/iap.egressor` to the BigQuery MCP server only, with a CEL
condition restricting to read-only tools:

```bash
gcloud beta iap web get-iam-policy --project="$PROJECT_ID" \
  --resource-type=agent-registry --region="$REGION" --mcp-server=MCP_SERVER_ID
# edit policy: role roles/iap.egressor, member principal://...reasoningEngines/ID,
# condition expression:
#   api.getAttribute('iap.googleapis.com/mcp.tool.isReadOnly', false) == true
gcloud beta iap web set-iam-policy policy.json --project="$PROJECT_ID" \
  --resource-type=agent-registry --region="$REGION" --mcp-server=MCP_SERVER_ID
```

Note: `principalSet://` (all-agents) is rejected at per-mcp-server scope —
use the single-agent `principal://` there.

## Phase 4 — Test and verify traffic transits the gateway

```bash
PROJECT_ID="$PROJECT_ID" LOCATION="$REGION" \
  python scripts/remote_smoke_test.py "$AGENT_ENGINE_ID"

# Gateway data-plane logs (hostname, matched registry entry, MCP tool name):
gcloud logging read 'resource.type="networkservices.googleapis.com/Gateway"
  resource.labels.gateway_name="'$GATEWAY_ID'"' \
  --project="$PROJECT_ID" --limit=30 --freshness=15m

# IAP allow/deny decisions (denials say: "Egress request is not authorized"):
gcloud logging read 'protoPayload.serviceName="iap.googleapis.com" severity>=WARNING' \
  --project="$PROJECT_ID" --limit=20 --freshness=15m
```

Success = the smoke test answers AND the gateway log shows the
`bigquery.googleapis.com` traffic with your agent's principal.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| Tool error, IAP log says `Egress request is not authorized` | Missing/stale `roles/iap.egressor` (re-run Phase 3 with the CURRENT engine ID) or the exact hostname isn't registered (Phase 1 — matching is exact, register the precise host from the gateway log). |
| Agent never becomes ready / startup failures after binding | IAP is ENFORCING and bootstrap hostnames aren't registered+authorized (Phase 1). Ask your preview contact to flip the IAP extension to `iamEnforcementMode: DRY_RUN` for onboarding. |
| Runtime logs: `Failed to send request to https://...mtls.googleapis.com/...` (retrying aiohttp errors, e.g. on the sessions API) | The SDKs auto-switch to `.mtls.` endpoint variants (Agent Identity certs present) and that exact hostname isn't registered — run the Phase 1 permutation loop (includes `-mtls` entries), then retry. |
| `401 Unauthorized` from `bigquery.googleapis.com/mcp` | Certificate-bound token rejection — keep `GOOGLE_API_PREVENT_AGENT_TOKEN_SHARING_FOR_GCP_SERVICES=false` in `.env` (ships as env var; the official gateway sample sets it too). |
| Deploy fails with pydantic `ValidationError` on `agent_gateway_config` | Deploy venv has `google-cloud-aiplatform < 1.148.0` — `pip install -r bq_analyst/requirements.txt --upgrade`. |
| `Invalid choice: 'agent-gateways'` / missing `--mcp-server` flags | gcloud too old — needs ≥ 570.0.0 (`gcloud components update`). |
| Second agent fails to bind: `Internal error encountered` | Known preview issue: one bonded engine per project. Delete the other bonded engine or use another project; confirm status with your preview contact. |
| MCP session dies at initialize although tools are allowed | A custom ALLOW `httpRules` policy on the gateway lacks `baseProtocolMethodsOption: MATCH_BASE_PROTOCOL_METHODS`. |
| 400 when granting `principalSet://` per-mcp-server | Expected — IAP only accepts single-agent `principal://` at that scope. |

## Confirm with your Google preview contact (not publicly documented)

1. Is the one-bonded-engine-per-project limitation still current?
2. Does the auto-registered (global) BigQuery MCP server satisfy a regional
   registry reference, or must it be manually registered per-region (as Phase 1
   does defensively)?
3. Is `GOOGLE_API_PREVENT_AGENT_TOKEN_SHARING_FOR_GCP_SERVICES=false` still
   required when traffic goes through the gateway (DPoP path), or can the
   opt-out be removed once bound?
4. MCP streamable-HTTP/SSE behavior through the gateway: session affinity,
   timeouts, and Model Armor (`CONTENT_AUTHZ`) interaction with streaming.
5. Preview pricing/quotas for Agent Gateway data plane.
