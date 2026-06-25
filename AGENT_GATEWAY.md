# Routing this agent's MCP traffic through Agent Gateway (Agent-to-Anywhere)

> ## ⚠️ STATUS (June 25, 2026): NOT GA — binding needs per-project early access
> Despite third-party claims of GA, the **Agent-Engine↔Agent-Gateway binding**
> still requires a **per-project early-access entitlement**. Verified empirically:
> in a project *without* it, `adk deploy` creates the engine, then the bind step
> fails and rolls back:
> ```
> 400 FAILED_PRECONDITION: Agent Engine integration with Agent Gateway
> requires additional early-access activation for this Google Cloud project.
> ```
> The gateway/registry/authz APIs themselves may be allowlisted (you can create
> all the infra) — but **binding an agent is a separate gate**. What genuinely
> went GA (June 18, 2026) is **Agent Registry** and **Agent Observability**, not
> the gateway egress path. Treat binding as irreversible; the one-gateway-per-
> project+region limit and the dangling-reference delete-deadlock still apply.
>
> **To resume:** have your Google contact enable the *"Agent Engine + Agent
> Gateway integration"* early-access entitlement for your project, then run the
> runbook below. All the infra steps (gateway, registry, IAP authz) work today;
> only the final deploy/bind is gated.
>
> **GA-era note:** the IAP authz extension now requires
> `metadata.iapPolicyVersion: "V1"` (in addition to `iamEnforcementMode`) —
> already reflected in Phase 5 below.

This branch binds the agent to a Google Cloud **Agent Gateway** (Private
Preview / early-access) so all of its outbound MCP/tool traffic is governed by
the gateway: default-deny egress, per-tool IAM authorization (IAP for Agents),
full traffic logging, and optional Model Armor screening.

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

**⚠️ Registry scope is the #1 silent killer**: if `registries:` points at
`locations/global` (the Gemini Enterprise scope), the gateway consults a
registry where none of your regional registrations exist and **default-denies
all egress** — symptoms look like TLS/network failures inside the container.
For Agent Runtime the gateway must reference the REGIONAL registry. Fix by
re-importing the gateway YAML:

```bash
gcloud alpha network-services agent-gateways export "$GATEWAY_ID" \
  --location="$REGION" --destination=/tmp/gw.yaml
# Edit /tmp/gw.yaml: change locations/global -> locations/$REGION in registries,
# and DELETE output-only fields (agentGatewayCard, createTime, updateTime, etag).
sed -i "s|locations/global|locations/${REGION}|" /tmp/gw.yaml
python3 - <<'EOF'
import yaml
d = yaml.safe_load(open('/tmp/gw.yaml'))
for k in ('agentGatewayCard', 'createTime', 'updateTime', 'etag'):
    d.pop(k, None)
yaml.safe_dump(d, open('/tmp/gw.yaml', 'w'))
EOF
gcloud alpha network-services agent-gateways import "$GATEWAY_ID" \
  --source=/tmp/gw.yaml --location="$REGION"
```

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

Hostname matching is EXACT, and the SDK may dial any of FIVE permutations of
each API hostname (base, mTLS, locational, locational-mTLS, regional REP)
depending on version/region/mTLS state. Register the full set — this mirrors
the official demo (`GoogleCloudPlatform/cloud-networking-solutions` →
`demos/agent-gateway`), whose field manual calls hostname permutations "the
single biggest gotcha":

```bash
./scripts/register_gateway_endpoints.sh "$PROJECT_ID" "$REGION"
```

The script registers ~15 services × 5 permutations, idempotently (existing
entries are skipped). After deploying, iterate: smoke test → IAP audit log
names any still-unregistered hostname (`audited_resource_name:
unregisteredResource`) → register it → retry. The registry-wide
`roles/iap.egressor` grant from Phase 3 covers newly registered entries
automatically.

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
```

**How to read the logs** (from the official demo's debugging playbook —
IMPORTANT: ignore `requestMethod=CONNECT` entries, they're outer tunnel
records, not authz decisions):

```bash
# 1. IAP allow/deny decisions — THE authoritative signal. granted true/false,
#    the caller principal, and the resolved registry resource. If
#    labels."iap.googleapis.com/audited_resource_name" = "unregisteredResource"
#    the hostname isn't registered (exact-match miss) — register it (Phase 1).
gcloud logging read 'protoPayload.serviceName="iap.googleapis.com"
  protoPayload.authorizationInfo.permission="iap.webServiceVersions.egressViaIAP"' \
  --project="$PROJECT_ID" --limit=20 --freshness=15m

# 2. Gateway proxy decisions for calls IAP never saw (denied before IAP):
gcloud logging read 'jsonPayload.@type="type.googleapis.com/google.cloud.loadbalancing.type.LoadBalancerLogEntry"
  -httpRequest.requestMethod="CONNECT"
  resource.labels.gateway_type="SECURE_WEB_GATEWAY"' \
  --project="$PROJECT_ID" --limit=20 --freshness=15m
# Key fields: httpRequest.status, httpRequest.requestUrl (exact destination),
# jsonPayload.authzPolicyInfo.policies.result
```

Success = the smoke test answers AND the IAP audit log shows
`granted: true` entries for the BigQuery destination with your agent's
`principal://...` as `principalSubject`.

## Phase 5 — One-shot diagnostics (when anything fails)

Stop debugging one command at a time — collect every signal at once and read
the report top to bottom:

```bash
./scripts/diagnose_gateway.sh "$PROJECT_ID" "$REGION" "$AGENT_ENGINE_ID" "$GATEWAY_ID"
```

How to read it: §3 empty → **no authz policy targets the gateway** (demo
known-issue #4: the IAP extension may exist but is not attached — everything
is denied at the proxy and §7 will be empty too). §6 missing the agent's
`principal://` under `roles/iap.egressor` → grant didn't land (re-run Phase 3
with gcloud ≥ 570). §7 `granted: false` → grant/principal mismatch; §7 label
`unregisteredResource` → register that exact hostname. §8 shows the inner
requests' status + URL for anything denied before/without IAP.

If §3 IS empty, attach IAP to the gateway (from the official demo):

```bash
# NOTE: metadata now REQUIRES iapPolicyVersion: "V1" (literal). The older
# gcloud `import` from a YAML lacking it silently no-ops — prefer the REST
# create below, which surfaces the real error.
TOKEN=$(gcloud auth print-access-token)
curl -s -X POST -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  "https://networkservices.googleapis.com/v1beta1/projects/${PROJECT_ID}/locations/${REGION}/authzExtensions?authzExtensionId=agent-gateway-iap-authz" \
  -d '{"service":"iap.googleapis.com","failOpen":true,"timeout":"1s","metadata":{"iamEnforcementMode":"DRY_RUN","iapPolicyVersion":"V1"}}'
# poll the returned operation until done=true before creating the policy.

curl -fsS -H "Authorization: Bearer $(gcloud auth print-access-token)" \
  -H "Content-Type: application/json" \
  -X POST "https://networksecurity.googleapis.com/v1alpha1/projects/${PROJECT_ID}/locations/${REGION}/authzPolicies?authz_policy_id=agent-gateway-iap-policy" \
  -d '{
    "name": "agent-gateway-iap-policy",
    "policyProfile": "REQUEST_AUTHZ",
    "action": "CUSTOM",
    "target": {"resources": ["projects/'"${PROJECT_ID}"'/locations/'"${REGION}"'/agentGateways/'"${GATEWAY_ID}"'"]},
    "customProvider": {"authzExtension": {"resources": ["projects/'"${PROJECT_ID}"'/locations/'"${REGION}"'/authzExtensions/agent-gateway-iap-authz"]}}
  }'
```

(`DRY_RUN` = decisions logged but not enforced — the safe onboarding mode;
remove the metadata block later to enforce.)

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| Tool error, IAP log says `Egress request is not authorized` | Missing/stale `roles/iap.egressor` (re-run Phase 3 with the CURRENT engine ID) or the exact hostname isn't registered (Phase 1 — matching is exact, register the precise host from the gateway log). |
| Agent never becomes ready / startup failures after binding | IAP is ENFORCING and bootstrap hostnames aren't registered+authorized (Phase 1). Ask your preview contact to flip the IAP extension to `iamEnforcementMode: DRY_RUN` for onboarding. |
| Runtime logs: `Cannot connect to host ...googleapis.com:443 ... [Network is unreachable]` (plain, non-mtls hostname) | Someone disabled client certs (`GOOGLE_API_USE_CLIENT_CERTIFICATE=false`). DON'T — the agent→gateway leg IS the client-cert mTLS channel, and gateway-bound containers have no direct egress, so plain hostnames are unroutable. Remove the var and redeploy; register the `.mtls.` hostname permutations instead (Phase 1 script does). |
| Runtime logs: `Failed to send request to https://...mtls.googleapis.com/...` | The mtls call failed *through* the gateway. NOT a transport bug — check, in order: (a) is that exact `.mtls.` hostname registered (Phase 1 permutations)? (b) does the IAP audit log show `granted: false` or `unregisteredResource` for it? (c) is the bound-token opt-out env var REALLY `false` in the deployed env (one var per line — see the corrupted-.env trap below)? |
| Deployed env shows two variables fused into one value (e.g. `"value": "falseGOOGLE_API_USE_CLIENT_CERTIFICATE=false"`) | `.env` line corruption — usually `echo >>` onto a file whose last line lacked a trailing newline. Rewrite `.env` with one `KEY=value` per line and redeploy; this silently disables the opt-out and re-enables bound tokens. |
| Gateway log shows `CONNECT` to `240.0.0.x` matched by `default_denied` | **Ignorable outer-tunnel records** (per the official demo's field manual) — the mTLS tunnel to the gateway itself. Do not treat as denials; exclude with `-httpRequest.requestMethod="CONNECT"` and judge from the IAP audit log. |
| IAP audit log permanently EMPTY while all egress fails with assorted TLS/network errors | Two gateway-level misconfigs to check (Phase 0/5): (1) `registries:` points at `locations/global` instead of the regional registry — fix via export/edit/import (see Phase 0); (2) no authz policy targets the gateway — attach the IAP extension + policy (see Phase 5). Both make the proxy default-deny before IAP ever runs. |
| `401 Unauthorized` from `bigquery.googleapis.com/mcp` | Certificate-bound token rejection — keep `GOOGLE_API_PREVENT_AGENT_TOKEN_SHARING_FOR_GCP_SERVICES=false` in `.env` (ships as env var; the official gateway sample sets it too). |
| Deploy fails with pydantic `ValidationError` on `agent_gateway_config` | Deploy venv has `google-cloud-aiplatform < 1.148.0` — `pip install -r bq_analyst/requirements.txt --upgrade`. |
| `Invalid choice: 'agent-gateways'` / missing `--mcp-server` flags | gcloud too old — needs ≥ 570.0.0 (`gcloud components update`). |
| Second agent fails to bind: `Internal error encountered` | Known preview issue: one bonded engine per project. Delete the other bonded engine or use another project; confirm status with your preview contact. |
| MCP session dies at initialize although tools are allowed | A custom ALLOW `httpRules` policy on the gateway lacks `baseProtocolMethodsOption: MATCH_BASE_PROTOCOL_METHODS`. |
| 400 when granting `principalSet://` per-mcp-server | Expected — IAP only accepts single-agent `principal://` at that scope. |
| Startup fails: `Failed to convert project number to project ID` / `Assembly Service failed to initialize` | Agent identity lacks `roles/browser` (`resourcemanager.projects.get` during SDK init) — included in the updated grant script; re-run it. |
| Runtime stderr: `ssl_transport_security.cc ... CERTIFICATE_VERIFY_FAILED: self signed certificate in certificate chain`, then `create_session` returns `FAILED_PRECONDITION: Reasoning Engine Execution failed` | **An egress denial in TLS costume.** The runtime wrapper's `set_up()` makes an unconditional gRPC call to `cloudresourcemanager.googleapis.com` (`AdkApp.project_id()` → `get_project`); when the gateway DENIES a destination it presents its own (self-signed) cert, which gRPC's baked-in roots reject; the failure escapes the wrapper's exception handler and kills startup. Allowed traffic passes with normal public certs (the official demo makes this same call successfully). Fix the AUTHORIZATION, not TLS: run `scripts/diagnose_gateway.sh` and check §3 (authz policy targeting the gateway exists?), §6 (egressor binding present?), §5 (cloudresourcemanager registered incl. `-mtls`?), §7 (IAP verdicts). |
| Gateway log shows only `CONNECT` entries | Those are outer tunnel records, NOT authz decisions — exclude them (`-httpRequest.requestMethod="CONNECT"`) and read the IAP audit log instead (Phase 4). |
| IAP audit shows denial but the binding looks correct | Check Principal Access Boundary policies (`gcloud iam principal-access-boundary-policies list --organization=ORG_ID --location=global`) — PAB overrides IAM Allow. |

**Reference implementation:** the official working demo is
[`GoogleCloudPlatform/cloud-networking-solutions` → `demos/agent-gateway`](https://github.com/GoogleCloudPlatform/cloud-networking-solutions/tree/main/demos/agent-gateway)
— its `.agents/skills/agent-platform-debugger/references/` directory (field
manual, known issues) is the best debugging companion for this stack.

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
