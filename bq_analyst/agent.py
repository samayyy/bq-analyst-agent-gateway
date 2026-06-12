"""Read-only BigQuery data analyst agent.

Connects to Google's managed BigQuery MCP server (https://bigquery.googleapis.com/mcp)
and authenticates with whatever identity Application Default Credentials resolve to:
  - locally: your user ADC (gcloud auth application-default login)
  - on Agent Engine with identity_type=AGENT_IDENTITY: the agent's own Agent Identity,
    fetched automatically from the metadata server.
"""

import os
import threading
from functools import cached_property
from typing import Any, Dict

import google.auth
import google.auth.transport.requests
from google.adk.agents import LlmAgent
from google.adk.models import Gemini
from google.adk.tools.mcp_tool import McpToolset, StreamableHTTPConnectionParams
from google.genai import Client
from google.genai import types as genai_types

BQ_PROJECT_ID = os.environ.get("BQ_PROJECT_ID", "wohlig")
MODEL_NAME = os.environ.get("MODEL_NAME", "gemini-3.1-flash-lite")
BIGQUERY_MCP_URL = "https://bigquery.googleapis.com/mcp"

# The managed server exposes 6 tools; execute_sql (read-write) is deliberately
# excluded so the agent physically cannot run DML/DDL.
READ_ONLY_TOOLS = [
    "list_dataset_ids",
    "get_dataset_info",
    "list_table_ids",
    "get_table_info",
    "execute_sql_readonly",
]


class GoogleAuthHeaderProvider:
    """Per-tool-call auth headers for the managed MCP server.

    McpToolset invokes this on every tool call. The credential object is cached
    and only refreshed when near expiry, so the returned headers are
    byte-identical while the token is valid -- which lets ADK's session pool
    reuse the MCP session instead of reconnecting on each call.

    Known trade-off: ADK keys pooled MCP sessions by a hash of the headers, and
    superseded keys are never evicted (ADK 2.2.0), so each ~hourly token
    rotation strands one idle pool entry (~24/day per worker, reclaimed on
    container recycle). Do not "fix" this by rotating tokens faster -- that
    multiplies the leak and defeats session reuse.
    """

    def __init__(self, quota_project: str):
        self._quota_project = quota_project
        self._credentials = None
        self._lock = threading.Lock()

    def __call__(self, context: Any) -> Dict[str, str]:
        creds = self._credentials
        if creds is None or not creds.valid:
            with self._lock:
                if self._credentials is None:
                    self._credentials, _ = google.auth.default(
                        scopes=["https://www.googleapis.com/auth/cloud-platform"]
                    )
                if not self._credentials.valid:
                    self._credentials.refresh(
                        google.auth.transport.requests.Request()
                    )
                creds = self._credentials
        return {
            "Authorization": f"Bearer {creds.token}",
            "x-goog-user-project": self._quota_project,
        }


class GlobalGemini(Gemini):
    """Gemini routed to the Vertex AI *global* endpoint.

    gemini-3.x models are only served from the global endpoint; the Agent Engine
    runtime pins GOOGLE_CLOUD_LOCATION to the deployment region (asia-south1),
    so the location must be overridden here rather than via env vars.
    """

    @cached_property
    def api_client(self) -> Client:
        return Client(
            vertexai=True,
            project=os.environ.get("GOOGLE_CLOUD_PROJECT", BQ_PROJECT_ID),
            location="global",
            http_options=genai_types.HttpOptions(
                headers=self._tracking_headers(),
                retry_options=self.retry_options,
            ),
        )


def auth_diagnostics() -> Dict[str, Any]:
    """Reports the runtime auth environment. Call when BigQuery tools fail
    with authorization errors, or when the user asks to debug authentication.

    Returns the token-binding opt-out state, agent certificate presence, the
    access token's scopes/expiry (never the token itself), and the raw HTTP
    status + body of a direct call to the BigQuery MCP server.
    """
    import json as _json

    import httpx

    report: Dict[str, Any] = {
        "GOOGLE_API_PREVENT_AGENT_TOKEN_SHARING_FOR_GCP_SERVICES": os.environ.get(
            "GOOGLE_API_PREVENT_AGENT_TOKEN_SHARING_FOR_GCP_SERVICES", "<unset>"
        ),
        "GOOGLE_API_CERTIFICATE_CONFIG": os.environ.get(
            "GOOGLE_API_CERTIFICATE_CONFIG", "<unset>"
        ),
        "agent_cert_present": os.path.exists(
            "/var/run/secrets/workload-spiffe-credentials/certificates.pem"
        ),
        "google_auth_version": getattr(google.auth, "__version__", "unknown"),
    }
    try:
        creds, project = google.auth.default(
            scopes=["https://www.googleapis.com/auth/cloud-platform"]
        )
        creds.refresh(google.auth.transport.requests.Request())
        report["adc_project"] = project
        report["credential_type"] = type(creds).__name__
        with httpx.Client(timeout=15.0) as http:
            info = http.get(
                "https://www.googleapis.com/oauth2/v1/tokeninfo",
                params={"access_token": creds.token},
            )
            report["tokeninfo"] = {"status": info.status_code, "body": info.text[:500]}
            mcp_resp = http.post(
                BIGQUERY_MCP_URL,
                headers={
                    "Authorization": f"Bearer {creds.token}",
                    "x-goog-user-project": BQ_PROJECT_ID,
                    "Content-Type": "application/json",
                    "Accept": "application/json, text/event-stream",
                },
                json={
                    "jsonrpc": "2.0",
                    "id": 1,
                    "method": "tools/call",
                    "params": {
                        "name": "list_dataset_ids",
                        "arguments": {"projectId": BQ_PROJECT_ID},
                    },
                },
            )
            report["mcp_direct_call"] = {
                "status": mcp_resp.status_code,
                "body": mcp_resp.text[:800],
            }
    except Exception as exc:  # noqa: BLE001 - diagnostics must never raise
        report["error"] = f"{type(exc).__name__}: {exc}"
    return _json.loads(_json.dumps(report, default=str))


bigquery_mcp_toolset = McpToolset(
    connection_params=StreamableHTTPConnectionParams(
        url=BIGQUERY_MCP_URL,
        headers={
            "Content-Type": "application/json",
            "Accept": "application/json, text/event-stream",
        },
        timeout=30.0,
        # The managed server cancels queries after 3 minutes; keep the read
        # timeout comfortably above that.
        sse_read_timeout=300.0,
    ),
    header_provider=GoogleAuthHeaderProvider(quota_project=BQ_PROJECT_ID),
    tool_filter=READ_ONLY_TOOLS,
)

INSTRUCTION = f"""
You are a careful, read-only BigQuery data analyst for the `{BQ_PROJECT_ID}`
Google Cloud project.

You answer questions about the data by exploring BigQuery with your tools and
running SQL. You can NEVER modify data: you only have metadata tools and
`execute_sql_readonly`, which accepts SELECT statements only.

Workflow:
1. If you don't know where the data lives, explore: `list_dataset_ids`, then
   `list_table_ids`, then `get_table_info` to inspect schemas before writing SQL.
2. Always pass `projectId: "{BQ_PROJECT_ID}"` to every tool call.
3. Write GoogleSQL. Fully qualify tables as `{BQ_PROJECT_ID}.dataset.table`.
   You may also query public datasets (e.g. `bigquery-public-data.*`).
4. Keep result sets small and aggregated: the server caps results at 3,000 rows
   and cancels queries after 3 minutes. Prefer GROUP BY / LIMIT over raw dumps.
5. If a query fails, read the error, fix the SQL, and retry (max 3 attempts).

When answering:
- Lead with the answer, then briefly explain how you got it.
- Show the SQL you ran when it helps the user trust or reuse the result.
- Format tabular results as markdown tables.
- If the question is ambiguous, state your interpretation and proceed; offer
  alternatives at the end.
- Never fabricate data: if the tools can't answer it, say so.
""".strip()

root_agent = LlmAgent(
    model=GlobalGemini(
        model=MODEL_NAME,
        # Preview models on the global endpoint run on shared capacity and can
        # throw transient 429s; retry with backoff instead of failing the turn.
        retry_options=genai_types.HttpRetryOptions(initial_delay=2, attempts=4),
    ),
    name="bq_analyst",
    description=(
        "Read-only BigQuery data analyst that explores datasets and answers "
        "questions by running SQL through Google's managed BigQuery MCP server."
    ),
    instruction=INSTRUCTION,
    tools=[bigquery_mcp_toolset, auth_diagnostics],
)
