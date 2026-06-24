#!/usr/bin/env bash
# Register the BigQuery endpoint (all 5 hostname permutations) in the Agent
# Registry across many regions. Idempotent: checks each region's registry BY URL
# and skips anything already present, so the "Interface URL already in use"
# error (code 3) never stops the run. Per-region failures (region not
# allowlisted for the preview) are reported and skipped, not fatal.
#
# NOTE: a registry entry only gates egress for a gateway in that SAME region.
# For a single us-central1 gateway you only need us-central1. Use this only if
# you genuinely run (or will run) gateways/agents in multiple regions.
#
# Usage: ./scripts/register_bigquery_all_regions.sh [PROJECT_ID]

set -uo pipefail

PROJECT_ID="${1:-gm-test-337806}"

# Regions where Agent Runtime / Agent Gateway are supported (edit as needed).
# Multi-regions (us, eu) are intentionally excluded — manual registration is
# not supported there.
REGIONS=(
  us-central1 us-east1 us-east4 us-west1
  europe-west1 europe-west2 europe-west3 europe-west4 europe-west6 europe-west8 europe-southwest1
  asia-east1 asia-east2 asia-northeast1 asia-northeast3 asia-south1 asia-southeast1 asia-southeast2
  australia-southeast2 me-west1 northamerica-northeast1 northamerica-northeast2 southamerica-east1
)

register_region() {
  local R="$1"
  echo "== $R =="
  # All URLs already registered in this region's registry (one API call).
  local existing
  existing=$(gcloud alpha agent-registry services list \
    --project="$PROJECT_ID" --location="$R" \
    --format="value(interfaces.url)" 2>/dev/null) || {
      echo "  [$R] SKIP — cannot list registry (region not enabled/allowlisted?)"
      return 0
    }

  # id  ->  url  (5 permutations)
  local -A want=(
    ["bigquery"]="https://bigquery.googleapis.com"
    ["bigquery-mtls"]="https://bigquery.mtls.googleapis.com"
    ["${R}-bigquery"]="https://${R}-bigquery.googleapis.com"
    ["${R}-bigquery-mtls"]="https://${R}-bigquery.mtls.googleapis.com"
    ["bigquery-${R}-rep"]="https://bigquery.${R}.rep.googleapis.com"
  )

  for id in "${!want[@]}"; do
    local url="${want[$id]}"
    if grep -qF "$url" <<<"$existing"; then
      echo "  [$R] exists: $url"
      continue
    fi
    if gcloud alpha agent-registry services create "$id" \
        --project="$PROJECT_ID" --location="$R" \
        --display-name="BigQuery ($id)" \
        --endpoint-spec-type=no-spec \
        --interfaces="url=$url,protocolBinding=JSONRPC" >/dev/null 2>&1; then
      echo "  [$R] registered: $url"
    else
      echo "  [$R] FAILED: $url (region not allowlisted, or id/URL conflict)"
    fi
  done
}

for R in "${REGIONS[@]}"; do
  register_region "$R"
done

echo
echo "Done. Verify a region with:"
echo "  gcloud alpha agent-registry services list --project=$PROJECT_ID --location=<REGION> --format='table(name.basename(),interfaces.url)' | grep -i bigquery"
