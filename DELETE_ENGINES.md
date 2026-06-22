# Delete the orphaned reasoning engines holding the gateway

These are the engine IDs the gateway-delete error named as still using
`my-bank-gateway-01`. Goal: delete any that are still live so the gateway frees
up and a new bond can succeed.

## Setup (same shell for all steps)

```bash
export TOKEN=$(gcloud auth print-access-token)
export BASE="https://us-central1-aiplatform.googleapis.com/v1beta1/projects/gm-test-337806/locations/us-central1"
```

> Re-run the TOKEN line if you start getting 401 (tokens expire ~1h).

## Step 1 — Check which engines still exist (200 = live, 404 = already gone)

```bash
for ID in 9079862129930010624 1635411945886580736 3216175415093624832; do
  echo -n "$ID -> "
  curl -s -o /dev/null -w "%{http_code}\n" -H "Authorization: Bearer $TOKEN" "$BASE/reasoningEngines/${ID}"
done
```

## Step 2 — Force-delete all three (skips the 404s harmlessly)

```bash
for ID in 9079862129930010624 1635411945886580736 3216175415093624832; do
  echo "=== Deleting $ID ==="
  curl -s -X DELETE -H "Authorization: Bearer $TOKEN" "$BASE/reasoningEngines/${ID}?force=true"
  echo
done
```

- A live engine returns an operation JSON (`"name": ".../operations/..."`).
- An already-gone engine returns `404 "The ReasoningEngine does not exist."`
  — harmless, means it was already deleted.

## Step 3 — Wait ~2 min, then re-check (want all 404)

```bash
for ID in 9079862129930010624 1635411945886580736 3216175415093624832; do
  echo -n "$ID -> "
  curl -s -o /dev/null -w "%{http_code}\n" -H "Authorization: Bearer $TOKEN" "$BASE/reasoningEngines/${ID}"
done
```

## Step 4 — Try the gateway delete again (or just redeploy)

```bash
# Old gateway should now delete if the references were live engines:
gcloud alpha network-services agent-gateways delete my-bank-gateway-01 --location=us-central1 --quiet
```

Then redeploy fresh against gw02 — see **DEPLOY_NEW_GATEWAY.md**.

## If everything was already 404 in Step 1

The references are phantom (deleted engines the gateway still lists). You cannot
delete them — there is nothing there. That is the dangling-bond deadlock; see
**ESCALATION.md** to hand it to the Google preview team.
