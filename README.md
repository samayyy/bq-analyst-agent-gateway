# BigQuery Analyst Agent (ADK + managed BigQuery MCP + Agent Identity)

A read-only conversational data analyst built with the Google Agent Development
Kit (ADK), connected to **Google's managed BigQuery MCP server**
(`https://bigquery.googleapis.com/mcp`), deployed on **Vertex AI Agent Engine**
(Agent Runtime) with a first-class **Agent Identity** as its IAM principal.

> **Deploying this into your own project?** Follow the step-by-step runbook in
> [DEPLOYMENT.md](DEPLOYMENT.md).

## Architecture

```
User ──> Agent Engine (your region, identity_type=AGENT_IDENTITY)
            │
            ├── gemini-3.1-flash-lite  ── Vertex AI GLOBAL endpoint
            │                             (model is not served regionally;
            │                              GlobalGemini subclass pins location="global")
            │
            └── McpToolset ───────────── https://bigquery.googleapis.com/mcp
                  │                       (managed, GA; Streamable HTTP)
                  ├ header_provider: per-tool-call Bearer token from
                  │   google.auth.default() -> the agent's own Agent Identity
                  │   (auto-refreshed near expiry; never goes stale)
                  └ tool_filter: read-only tools only
                      list_dataset_ids / get_dataset_info / list_table_ids /
                      get_table_info / execute_sql_readonly   (NO execute_sql)
```

Key design points:

- **Agent Identity** (`.agent_engine_config.json` → `identity_type: AGENT_IDENTITY`):
  the agent gets its own SPIFFE-based IAM principal — not a shared service
  account. Inside the runtime, `google.auth.default()` automatically returns
  the agent's identity from the metadata server.
- **Token refresh**: the widely-copied codelab pattern bakes a ~1h token into
  the MCP connection headers and breaks on long-lived deployments. Here a
  `header_provider` is invoked on every tool call; the cached credential
  refreshes only when near expiry, and ADK's session pool keys on the header
  hash, so a rotated token transparently creates a fresh MCP session.
- **Read-only by construction**: `execute_sql` (the only read-write MCP tool)
  is excluded via `tool_filter`, so the model cannot run DML/DDL even if asked.

## Stack

| | |
|---|---|
| Agent framework | `google-adk[a2a,mcp]==2.2.0` (Python 3.10–3.14) |
| Model | `gemini-3.1-flash-lite` (Vertex AI global endpoint only) |
| Tools | Managed BigQuery MCP server (GA), read-only subset |
| Runtime | Vertex AI Agent Engine / Agent Runtime |
| Identity | Agent Identity (per-agent IAM principal) |

## Local development

```bash
source .venv/bin/activate
cp bq_analyst/.env.example bq_analyst/.env   # then edit values
gcloud auth application-default login         # local auth = your user ADC
python scripts/local_smoke_test.py            # drives the agent in-process
adk web                                       # or chat in the dev UI at :8000
```

Your user needs `roles/mcp.toolUser`, `roles/bigquery.jobUser`,
`roles/bigquery.dataViewer` (or owner) on the project.

## Deploy / redeploy

See [DEPLOYMENT.md](DEPLOYMENT.md) for the full runbook (APIs, IAM, deploy,
identity grants, testing, troubleshooting). Short version:

```bash
adk deploy agent_engine --project=$PROJECT_ID --region=$REGION \
  --display_name="BigQuery Analyst" bq_analyst
./scripts/grant_agent_identity_iam.sh $PROJECT_ID $REGION $AGENT_ENGINE_ID
PROJECT_ID=$PROJECT_ID LOCATION=$REGION python scripts/remote_smoke_test.py $AGENT_ENGINE_ID
```

Redeploys: always pass `--agent_engine_id=$AGENT_ENGINE_ID` or the CLI creates
a duplicate engine. The CLI exits 0 even on failure — trust the
"Deployed to Agent Platform: ..." output line.

### Why `GOOGLE_API_PREVENT_AGENT_TOKEN_SHARING_FOR_GCP_SERVICES=false`?

Agent Identity access tokens are **certificate-bound** (Context-Aware Access
enforces mTLS proof-of-possession). ADK's MCP transport is raw httpx and cannot
present the binding yet — [google/adk-python#5361](https://github.com/google/adk-python/issues/5361) —
so bound tokens get `401 Unauthorized` from managed MCP servers. The env var in
`.env` is Google's documented opt-out: the runtime mints standard unbound
tokens (equivalent to normal service-account tokens). Remove it and retest once
#5361 is fixed. The deployed agent also has a temporary `auth_diagnostics` tool
that reports binding state, cert presence, token scopes, and a direct MCP call
result from inside the runtime.

## Known limits (managed BigQuery MCP server)

- Results capped at 3,000 rows; queries auto-cancel after 3 minutes.
- `execute_sql_readonly` accepts SELECT only (no DML/DDL/stored procedures).
- Google Drive external tables are not supported.
- All MCP-issued queries carry job label `goog-mcp-server: true` (auditable in
  `INFORMATION_SCHEMA.JOBS`).
