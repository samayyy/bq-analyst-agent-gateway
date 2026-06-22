# Recovery: orphaned engines, dangling gateway references, redeploy

## The paradox you're seeing (read this first)

> Deleting the gateway says it's *in use* by engines X, Y, Z.
> Deleting those engines says they *don't exist*, and they're not in the console.

This is a **known Agent Gateway preview bug — a dangling reference**:

- When a gateway-bonded Reasoning Engine is deleted, the engine resource IS
  removed (so `GET`/`DELETE` return `404` and it vanishes from the console)...
- ...but the gateway's internal "bound-by" reference is **NOT released**.
- So the gateway still reports the engine as a user, even though the engine is
  gone. You cannot delete what no longer exists — there is nothing there.

**There is no customer-side command to force-release a dangling reference.**
Only the Google preview team can clear it.

**You do NOT need to delete the old gateway.** Deleting it was only ever a way
to free the preview's "one bonded engine per project + region" slot. That slot
is consumed by **live** engines, not by stale references on a gateway you're
abandoning. So: delete the *live* engines, ignore the phantom (404) ones, leave
the old gateway alone, and deploy to the **new** gateway.

---

## Setup (same shell for every step; re-run if you get 401 after ~1h)

```bash
export PROJECT_ID="gm-test-337806"
export REGION="us-central1"
export TOKEN=$(gcloud auth print-access-token)
export BASE="https://us-central1-aiplatform.googleapis.com/v1beta1/projects/${PROJECT_ID}/locations/us-central1"
```

---

## Step 1 — Find which referenced engines are LIVE vs PHANTOM

The IDs come from the gateway-delete error message. Check existence:

```bash
for ID in 9079862129930010624 1635411945886580736 3216175415093624832; do
  echo -n "$ID -> "
  curl -s -o /dev/null -w "%{http_code}\n" -H "Authorization: Bearer $TOKEN" "$BASE/reasoningEngines/${ID}"
done
```

- `200` = **LIVE** → a real blocker, delete it in Step 2.
- `404` = **PHANTOM** (already deleted; stale gateway ref) → cannot delete,
  leave it. `1635411945886580736` is already known to be `404`.

---

## Step 2 — Delete ONLY the live engines (the 200s)

```bash
# Replace with the IDs that returned 200 in Step 1:
for ID in <LIVE_ID_1> <LIVE_ID_2>; do
  echo "=== Deleting engine $ID ==="
  curl -s -X DELETE -H "Authorization: Bearer $TOKEN" "$BASE/reasoningEngines/${ID}?force=true"
  echo
done
```

Each returns an operation JSON (not an error). Deletes are async — wait ~2 min,
then re-run Step 1; the deleted ones should flip to `404`.

> If a delete returns `404`, it was already a phantom — fine, move on.
> `force=true` does not help a `404`; nothing exists to delete.

---

## Step 3 — Do NOT delete the old gateway. Confirm the NEW gateway instead

Skip `agent-gateways delete` entirely (the dangling reference will keep
blocking it; that's the preview team's to fix, and you don't need it gone).

Confirm the NEW gateway is correctly configured and the config points at it:

```bash
# Registry MUST be regional (locations/us-central1), NOT global
gcloud alpha network-services agent-gateways describe <NEW_GW_ID> --location="$REGION" \
  --format="value(registries)"
# expect: //agentregistry.googleapis.com/projects/gm-test-337806/locations/us-central1

# An authz policy must target the NEW gateway (you confirmed this exists)
curl -s -H "Authorization: Bearer $TOKEN" \
  "https://networksecurity.googleapis.com/v1alpha1/projects/${PROJECT_ID}/locations/${REGION}/authzPolicies" \
  | grep -o "agentGateways/[^\"]*"

# Deploy config points at the NEW gateway
grep agentGateway bq_analyst/.agent_engine_config.json
```

If the registry shows `locations/global`, fix it first (export → change
`global` to `us-central1` → strip output-only fields → import; see
AGENT_GATEWAY.md Phase 0).

---

## Step 4 — Deploy fresh against the NEW gateway

```bash
source .venv/bin/activate
adk deploy agent_engine --project="$PROJECT_ID" --region="$REGION" \
  --display_name="BigQueryAnalyst-v03-new-gateway" bq_analyst

export AGENT_ENGINE_ID="<numeric ID from the 'Created a new instance' line>"
```

(Trust the `Deployed to Agent Platform: .../reasoningEngines/<ID>` line — the
CLI exits 0 even on failure.)

---

## Step 5 — Grant IAM for the NEW engine identity (new ID = new principal)

```bash
./scripts/grant_agent_identity_iam.sh "$PROJECT_ID" "$REGION" "$AGENT_ENGINE_ID"
./scripts/grant_gateway_egress_iam.sh "$PROJECT_ID" "$REGION" "$AGENT_ENGINE_ID"
```

---

## Step 6 — Wait ~3 min, then test + capture the decision trail

```bash
PROJECT_ID="$PROJECT_ID" LOCATION="$REGION" python scripts/remote_smoke_test.py "$AGENT_ENGINE_ID"
bash scripts/diagnose_gateway.sh "$PROJECT_ID" "$REGION" "$AGENT_ENGINE_ID" <NEW_GW_ID>
```

---

## If Step 4 STILL fails with `code 13`

That means the dangling reference is genuinely still holding the one-bond slot
(a preview bug, not something you can fix from the client). Get the real error
and escalate to your Google preview contact:

```bash
NEW_ID=<id from the failed 'Created a new instance' line>
curl -s -H "Authorization: Bearer $TOKEN" "$BASE/reasoningEngines/${NEW_ID}/operations" | head -c 3000
```

**Escalation package for the preview team:**
- Deleted engine `1635411945886580736` (now `404`) still appears as a bound
  user of gateway `my-bank-gateway-01` — a dangling bind reference that blocks
  gateway deletion and new bonding (`code 13`).
- Ask them to force-release the stale binding (or delete the gateway
  server-side).
- Evidence: the `agent-gateways delete` "already being used by" error + the
  Step 1 `404` results + the `/operations` error above.
```

---

## TL;DR of the fix

1. The `404` engines are already deleted — there is nothing to delete; the
   gateway just holds stale references (preview bug).
2. Delete only the engines that GET returns `200` for.
3. Don't delete the old gateway — deploy to the new one instead.
4. If `code 13` persists with no live engines, it's a preview-side dangling
   bond → escalate to Google.
