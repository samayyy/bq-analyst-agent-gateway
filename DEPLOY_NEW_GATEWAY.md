# Deploy to the NEW gateway (fresh create)

## The mistake that caused `code 13`

The failing command used `--agent_engine_id=1635411945886580736`. That flag
means **update this existing engine** — but that engine is **deleted** (it
returns `404`). You cannot update a deleted engine, hence:

> Failed to **update** Agent Engine: {'code': 13, ...}

**Fix: drop `--agent_engine_id` entirely** to do a fresh **create** bound to the
new gateway. Use `--agent_engine_id` ONLY when updating a live engine in place.

---

## Setup (same shell for all steps)

```bash
export PROJECT_ID="gm-test-337806"
export REGION="us-central1"
```

---

## Step 1 — Confirm the config points at the NEW gateway

```bash
grep agentGateway bq_analyst/.agent_engine_config.json
```

Must show the NEW gateway's resource path
(`projects/gm-test-337806/locations/us-central1/agentGateways/<NEW_GW_ID>`),
NOT `my-bank-gateway-01`. If it's wrong, edit
`bq_analyst/.agent_engine_config.json` before deploying.

---

## Step 2 — Deploy fresh (NO --agent_engine_id)

```bash
source .venv/bin/activate
adk deploy agent_engine --project="$PROJECT_ID" --region="$REGION" \
  --display_name="BigQueryAnalyst-v03-new-gateway" \
  bq_analyst
```

Watch for: `Created a new instance: .../reasoningEngines/<NEW_ID>` and
`Deployed to Agent Platform: ...` (the CLI exits 0 even on failure, so trust the
printed line, not the exit code). Copy the numeric ID:

```bash
export AGENT_ENGINE_ID="<numeric ID from 'Created a new instance'>"
```

---

## Step 3 — Grant IAM for the new engine identity

(New engine = new principal; old grants don't carry over.)

```bash
./scripts/grant_agent_identity_iam.sh "$PROJECT_ID" "$REGION" "$AGENT_ENGINE_ID"
./scripts/grant_gateway_egress_iam.sh "$PROJECT_ID" "$REGION" "$AGENT_ENGINE_ID"
```

---

## Step 4 — Wait ~3 min, then test

```bash
PROJECT_ID="$PROJECT_ID" LOCATION="$REGION" python scripts/remote_smoke_test.py "$AGENT_ENGINE_ID"
```

Full diagnostics + the IAP audit trail:

```bash
bash scripts/diagnose_gateway.sh "$PROJECT_ID" "$REGION" "$AGENT_ENGINE_ID" <NEW_GW_ID>
```

---

## If Step 2 STILL fails with `code 13` on a fresh create

Then the dangling-bond preview bug is holding the one-bonded-engine-per-project
slot (the deleted engine `1635411945886580736` still referenced by the old
gateway). This is not fixable client-side. Get the real error and escalate:

```bash
TOKEN=$(gcloud auth print-access-token)
BASE="https://us-central1-aiplatform.googleapis.com/v1beta1/projects/${PROJECT_ID}/locations/us-central1"
NEW_ID=<id from the failed 'Created a new instance' line>
curl -s -H "Authorization: Bearer $TOKEN" "$BASE/reasoningEngines/${NEW_ID}/operations" | head -c 3000
```

Escalation package for the Google preview contact:
- Deleted engine `1635411945886580736` (now `404`, absent from console) still
  appears as a bound user of gateway `my-bank-gateway-01` — a dangling bind
  reference blocking new bonding (`code 13`).
- Ask them to force-release the stale binding / delete the old gateway
  server-side.
- Evidence: the `agent-gateways delete` "already being used by" error, the
  engine `404`, and the `/operations` error above.

See also `RECOVERY_STEPS.md` for the full dangling-reference explanation.
```
