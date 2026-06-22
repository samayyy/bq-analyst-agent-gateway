# Agent Gateway preview escalation: dangling bond deadlock

## The deadlock

```
A new ReasoningEngine cannot bond to any Agent Gateway (deploy fails code 13
INTERNAL on the bind/update step) because the project's single bond slot
(private-preview "one active RE<->AGW bonding per project" limit) is already
held by a binding to a DELETED engine. That dead engine cannot be deleted
(404, already gone) and the old gateway cannot be deleted (reports it is still
"in use" by that dead engine). Circular: nothing on the customer API releases a
dangling bond to a non-existent resource.
```

## Project / resources

- Project: `gm-test-337806` (number `719187342121`), region `us-central1`
- Old gateway (undeletable): `my-bank-gateway-01`
- New gateway (cannot bond to): `gw02`
- Dead engine still referenced by old gateway: `1635411945886580736`
- Other referenced IDs: `9079862129930010624`, `3216175415093624832`

## Confirm before escalating — are ALL referenced engines phantom?

```bash
TOKEN=$(gcloud auth print-access-token)
BASE="https://us-central1-aiplatform.googleapis.com/v1beta1/projects/gm-test-337806/locations/us-central1"
for ID in 9079862129930010624 1635411945886580736 3216175415093624832; do
  echo -n "$ID -> "; curl -s -o /dev/null -w "%{http_code}\n" -H "Authorization: Bearer $TOKEN" "$BASE/reasoningEngines/${ID}"
done
```

- Any `200` -> that engine is LIVE; delete it and the deadlock breaks WITHOUT
  escalation:
  ```bash
  curl -s -X DELETE -H "Authorization: Bearer $TOKEN" "$BASE/reasoningEngines/<LIVE_ID>?force=true"
  # wait ~2 min, then redeploy (see DEPLOY_NEW_GATEWAY.md)
  ```
- All `404` -> confirmed deadlock; escalate with the message below.

## Evidence to collect for the ticket

```bash
# 1. Gateway-delete error naming the dead engine(s) as users:
gcloud alpha network-services agent-gateways delete my-bank-gateway-01 --location=us-central1

# 2. Proof the referenced engine is gone:
curl -s -o /dev/null -w "%{http_code}\n" -H "Authorization: Bearer $TOKEN" \
  "$BASE/reasoningEngines/1635411945886580736"   # 404

# 3. The code-13 root error from a fresh bond attempt (run a deploy, then):
gcloud logging read 'resource.type="aiplatform.googleapis.com/ReasoningEngine" severity>=ERROR' \
  --project=gm-test-337806 --limit=10 --freshness=30m --format="value(timestamp,textPayload)"
```

## Message to the Google Agent Gateway preview contact

> Subject: Agent Gateway private preview — dangling bond blocks all new bonding (project gm-test-337806)
>
> We are blocked deploying any gateway-bound agent in project `gm-test-337806`
> (number 719187342121), region us-central1.
>
> A previously deployed ReasoningEngine `1635411945886580736` was bonded to
> Agent Gateway `my-bank-gateway-01`. We deleted that engine; it is now gone
> (GET/DELETE return 404, and it is absent from the Agent Runtime console).
> However:
>
> 1. `agent-gateways delete my-bank-gateway-01` fails FAILED_PRECONDITION,
>    reporting it is still in use by reasoningEngines/1635411945886580736
>    (and 9079862129930010624, 3216175415093624832) — all of which return 404.
> 2. Deploying a brand-new engine bonded to a new gateway `gw02` fails with
>    code 13 INTERNAL on the bind/update step (the engine is created, then the
>    gateway bond fails and the engine is rolled back). We believe the single
>    per-project RE<->AGW bond slot is held by the dangling reference to the
>    deleted engine.
>
> Request: please force-release the stale binding from the deleted engine(s),
> or delete gateway `my-bank-gateway-01` server-side, so we can bond a new
> engine. There appears to be no customer-side API to release a binding to an
> already-deleted ReasoningEngine.
>
> Evidence attached: gateway-delete error, the 404 results, and the code-13
> operation/log error.

## After Google clears it

Redeploy fresh (no `--agent_engine_id`) against `gw02`, then grant IAM and test
— see `DEPLOY_NEW_GATEWAY.md`.
