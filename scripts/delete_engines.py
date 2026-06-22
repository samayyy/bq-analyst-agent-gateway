"""List and delete Vertex AI Agent Engine (Reasoning Engine) instances via the
SDK — robust against the Cloud Shell URL line-wrapping that breaks curl.

Verified against google-cloud-aiplatform 1.157.0:
  client = vertexai.Client(project, location, http_options=dict(api_version="v1beta1"))
  client.agent_engines.list()                      -> iterator of AgentEngine
  client.agent_engines.delete(name=..., force=True)  (force cascades child resources)

Usage:
  # List everything (authoritative — includes gateway-bound engines hidden from console):
  python scripts/delete_engines.py list

  # Delete specific IDs (full resource name or bare numeric id), force by default:
  python scripts/delete_engines.py delete 9079862129930010624 1635411945886580736 3216175415093624832

Env: PROJECT_ID and LOCATION (default gm-test-337806 / us-central1).
"""

import os
import sys

import vertexai

PROJECT_ID = os.environ.get("PROJECT_ID", "gm-test-337806")
LOCATION = os.environ.get("LOCATION", "us-central1")


def client():
    return vertexai.Client(
        project=PROJECT_ID,
        location=LOCATION,
        http_options=dict(api_version="v1beta1"),
    )


def full_name(engine_id: str) -> str:
    if engine_id.startswith("projects/"):
        return engine_id
    engine_id = engine_id.rsplit("/", 1)[-1]
    return f"projects/{PROJECT_ID}/locations/{LOCATION}/reasoningEngines/{engine_id}"


def cmd_list():
    c = client()
    found = False
    for e in c.agent_engines.list():
        found = True
        name = getattr(e, "name", getattr(e, "api_resource", None))
        eid = str(name).rsplit("/", 1)[-1]
        spec = getattr(e, "spec", None) or {}
        dep = (spec.get("deploymentSpec", {}) if isinstance(spec, dict) else {}) or {}
        gw = dep.get("agentGatewayConfig", "-")
        print(f"{eid}\t{getattr(e, 'display_name', '?')}\tgateway={gw}")
    if not found:
        print("(no reasoning engines in this project/region)")


def cmd_delete(ids):
    c = client()
    for raw in ids:
        name = full_name(raw)
        eid = name.rsplit("/", 1)[-1]
        try:
            c.agent_engines.delete(name=name, force=True)
            print(f"{eid} -> delete requested (force=True)")
        except Exception as exc:  # noqa: BLE001
            msg = str(exc)
            if "404" in msg or "does not exist" in msg or "NOT_FOUND" in msg:
                print(f"{eid} -> already gone (404) — nothing to delete")
            else:
                print(f"{eid} -> ERROR: {type(exc).__name__}: {msg[:300]}")


def main():
    if len(sys.argv) < 2 or sys.argv[1] not in ("list", "delete"):
        sys.exit(__doc__)
    if sys.argv[1] == "list":
        cmd_list()
    else:
        ids = sys.argv[2:]
        if not ids:
            sys.exit("Provide at least one engine ID to delete.")
        cmd_delete(ids)


if __name__ == "__main__":
    main()
