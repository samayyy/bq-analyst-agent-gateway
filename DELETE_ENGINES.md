# Delete the orphaned reasoning engines (researched / verified)

## What I verified

- **gcloud cannot do this** — `gcloud ... ai reasoning-engines` does not exist in
  the installed CLI (558.0.0). REST or SDK only.
- **Correct delete shape** (confirmed in google-cloud-aiplatform 1.157.0 source):
  `DELETE .../v1beta1/projects/PROJECT/locations/REGION/reasoningEngines/{id}?force=true`
  — `force` is a query param, `v1beta1` is the right version, `force=true`
  cascades child resources (sessions/memory). So the earlier curl was correct,
  and a `404` genuinely means the engine is already gone.
- **Why prefer the SDK script below over curl:** Cloud Shell has repeatedly
  line-wrapped the long curl URL (the first delete broke on a mid-ID wrap).
  `scripts/delete_engines.py` uses the SDK (`client.agent_engines.delete`),
  which builds the exact URL/version/force internally — nothing to wrap — and
  lists what *actually* exists straight from the API.

## Setup

```bash
cd ~/agent-gw/bq-analyst-agent-gateway   # or wherever the repo + .venv live
source .venv/bin/activate
export PROJECT_ID="gm-test-337806"
export LOCATION="us-central1"
```

## Step 1 — Authoritative list of ALL engines (incl. gateway-bound/hidden)

```bash
python scripts/delete_engines.py list
```

This is the real source of truth — more reliable than the console (which hides
gateway-bound engines) or a hand-written curl list call.

## Step 2 — Delete the three referenced engines (force; 404s are safe skips)

```bash
python scripts/delete_engines.py delete 9079862129930010624 1635411945886580736 3216175415093624832
```

Output per ID:
- `delete requested (force=True)` -> it was **live**; now deleting (good — a
  live engine was holding the one-bond slot).
- `already gone (404)` -> phantom; nothing to delete.
- `ERROR: ...` -> paste it; that's a real problem (perms / wrong project).

## Step 3 — Wait ~2 min, re-list (should be empty or shrunk)

```bash
python scripts/delete_engines.py list
```

## Step 4 — Then either delete the old gateway or just redeploy

```bash
gcloud alpha network-services agent-gateways delete my-bank-gateway-01 --location=us-central1 --quiet
# then redeploy fresh against gw02 -> DEPLOY_NEW_GATEWAY.md
```

## Fallback (no venv / SDK available) — raw REST, single line each

```bash
TOKEN=$(gcloud auth print-access-token)
BASE="https://us-central1-aiplatform.googleapis.com/v1beta1/projects/gm-test-337806/locations/us-central1"
curl -s -X DELETE -H "Authorization: Bearer $TOKEN" "$BASE/reasoningEngines/9079862129930010624?force=true"; echo
curl -s -X DELETE -H "Authorization: Bearer $TOKEN" "$BASE/reasoningEngines/3216175415093624832?force=true"; echo
curl -s -X DELETE -H "Authorization: Bearer $TOKEN" "$BASE/reasoningEngines/1635411945886580736?force=true"; echo
```
(Keep each curl on ONE line — never let the terminal wrap the URL mid-ID.)

## If every ID is `already gone (404)` and the gateway still won't delete

The references are phantom (deleted engines the gateway still lists) — the
dangling-bond deadlock. No client-side command releases it. See
**ESCALATION.md**.
