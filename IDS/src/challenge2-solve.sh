#!/bin/bash

set -euo pipefail

BASE_URL="http://localhost:8081"
AUTH="Authorization: Basic U3lzdGVtQWRtaW46c3lz"

BUREAU_STORE_NAME="BureauStore"
BUREAU_STORE_DESCRIPTION="Credit bureau data containing customer credit accounts, including credit type and status, currency, credit amounts, outstanding debt, credit limits, overdue amounts and days, account duration, and credit prolongations. Use this Knowledge Store for questions about customers’ credit history, active or overdue accounts, debt and credit exposure, credit types and currencies, and prolonged credits."

NARRATIVE_NAME="Bureau Data Narrative"
NARRATIVE_DESCRIPTION="Narrative to get Bureau Data Info"
TABLE_NAME="Sample.BureauData"
SQL_QUERY="SELECT * FORM Sample.BureauData WHERE ID = '{{ID}}'"

NARRATIVE_TEMPLATE="Customer {{SK_ID_CURR}} has a credit bureau record {{ID}} for a {{CREDIT_TYPE}} account. The account is currently {{CREDIT_ACTIVE}} and is denominated in {{CREDIT_CURRENCY}}. The credit was granted {{DAYS_CREDIT}} days before the customer's application. It is currently {{CREDIT_DAY_OVERDUE}} days overdue, has been prolonged {{CNT_CREDIT_PROLONG}} times, and has a total credit amount of {{AMT_CREDIT_SUM}}. The outstanding debt is {{AMT_CREDIT_SUM_DEBT}}, the available credit limit is {{AMT_CREDIT_SUM_LIMIT}}, the current overdue balance is {{AMT_CREDIT_SUM_OVERDUE}}, and the maximum overdue amount ever recorded is {{AMT_CREDIT_MAX_OVERDUE}}. The credit is expected to end in {{DAYS_CREDIT_ENDDATE}} days, was actually closed after {{DAYS_ENDDATE_FACT}} days (if applicable), was last updated {{DAYS_CREDIT_UPDATE}} days before the application, and has an annuity payment amount of {{AMT_ANNUITY}}."

API="${BASE_URL}/intersystems/semantic-search/v1"
MAX_WAIT_SECONDS="${MAX_WAIT_SECONDS:-1200}"
POLL_SECONDS=5

log() { printf '%s\n' "$*"; }
fail() { log "ERROR: $*" >&2; exit 1; }

get_stores() { curl -fsS --retry 2 --max-time 30 --header "$AUTH" "$API/knowledgeStore"; }
get_narratives() { curl -fsS --retry 2 --max-time 30 --header "$AUTH" "$API/narratives"; }

active_store_id() {
  get_stores | jq -r --arg name "$1" '
    [.knowledgeStores[] | select(.name == $name and .status != "D")]
    | if length > 0 then max_by(.id | tonumber).id else empty end'
}

narrative_id_for_store() {
  get_narratives | jq -r --arg name "$1" --arg storeId "$2" '
    first(.items[] | select(.name == $name and (.knowledgeStoreId | tostring) == $storeId) | .id) // empty'
}

narrative_info() {
  get_narratives | jq -c --arg id "$1" '
    first(.items[] | select((.id | tostring) == $id)) // empty'
}

# Retry transient API errors; don't treat an HTTP 500 as successful.
start_narrative() {
  local id="$1" name="$2" attempt http response status
  response=$(mktemp)
  for attempt in $(seq 1 12); do
    status=$(narrative_info "$id" | jq -r '.status.processingStatus // empty')
    if [ "$status" = "TR" ]; then
      log "$name already Ready."
      rm -f "$response"
      return 0
    fi
    http=$(curl -sS --max-time 30 -o "$response" -w '%{http_code}' \
      -X PUT --header "$AUTH" \
      "$API/narratives/$id/processing?shouldStart=true") || http=000
    if [[ "$http" =~ ^2[0-9][0-9]$ ]]; then
      log "$name: start request accepted (HTTP $http)."
      rm -f "$response"
      return 0
    fi
    log "$name: start attempt $attempt failed (HTTP $http)."
    if [ "$attempt" -eq 12 ]; then
      cat "$response" >&2
      rm -f "$response"
      fail "Could not start $name"
    fi
    sleep 5
  done
}

# Bounded wait with explicit missing/failed checks.
wait_both() {
  local deadline=$((SECONDS + MAX_WAIT_SECONDS)) bureau catalog bstatus cstatus
  while [ "$SECONDS" -lt "$deadline" ]; do
    bureau=$(narrative_info "$BUREAU_NARRATIVE_ID")
    catalog=$(narrative_info "$CATALOG_NARRATIVE_ID")
    [ -n "$bureau" ] && [ -n "$catalog" ] || fail "A required narrative disappeared."
    bstatus=$(jq -r '.status.processingStatus // empty' <<< "$bureau")
    cstatus=$(jq -r '.status.processingStatus // empty' <<< "$catalog")
    log "Bureau: $bstatus ($(jq -r '.status.percentageEmbeddingsUpToDate // "?"' <<< "$bureau") up-to-date); Data Catalog: $cstatus"
    for item in "$bureau" "$catalog"; do
      failed=$(jq -r '.status.totalRecordsFailed // 0' <<< "$item")
      [ "$failed" -eq 0 ] || fail "Narrative has $failed failed records: $item"
    done
    if [ "$bstatus" = TR ] && [ "$cstatus" = TR ] && \
       [ "$(jq -r '.status.pendingItems // 0' <<< "$bureau")" -eq 0 ] && \
       [ "$(jq -r '.status.pendingItems // 0' <<< "$catalog")" -eq 0 ]; then
      log "SUCCESS: Both Bureau Data and Data Catalog narratives are Ready."
      return 0
    fi
    sleep "$POLL_SECONDS"
  done
  fail "Narratives did not both reach Ready within ${MAX_WAIT_SECONDS}s."
}

log "Waiting for Semantic Search API..."
ready=false
for i in $(seq 1 60); do
  if get_stores >/dev/null 2>&1; then ready=true; break; fi
  sleep 5
done
[ "$ready" = true ] || fail "Semantic Search API unavailable"

EMBEDDING_ID=$(curl -fsS --header "$AUTH" "$API/embedding?configuredOnly=true" |
  jq -r 'first((.embeddings // [])[] | select(.name == "text-embedding-3-small" and .vendorName == "OpenAI") | .id) // empty')
[ -n "$EMBEDDING_ID" ] || fail "OpenAI embedding model not found"

# Create/update BureauStore.
BUREAU_STORE_ID=$(active_store_id "$BUREAU_STORE_NAME")
BUREAU_STORE_PAYLOAD=$(jq -n --arg name "$BUREAU_STORE_NAME" \
  --arg description "$BUREAU_STORE_DESCRIPTION" --argjson embeddingId "$EMBEDDING_ID" \
  '{name:$name,knowledgeStoreType:"Collection",embeddingId:$embeddingId,enabled:true,description:$description,roles:["System Administrator"],questions:[]}')
if [ -z "$BUREAU_STORE_ID" ]; then
  log "Creating BureauStore..."
  curl -fsS -X POST --header "$AUTH" -H 'Content-Type: application/json' \
    --data "$BUREAU_STORE_PAYLOAD" "$API/knowledgeStore" >/dev/null
else
  log "Updating BureauStore..."
  curl -fsS -X PUT --header "$AUTH" -H 'Content-Type: application/json' \
    --data "$BUREAU_STORE_PAYLOAD" "$API/knowledgeStore/$BUREAU_STORE_ID" >/dev/null
fi

BUREAU_STORE_ID=""
for i in $(seq 1 60); do
  BUREAU_STORE_ID=$(get_stores | jq -r --arg name "$BUREAU_STORE_NAME" '
    [.knowledgeStores[] | select(.name == $name and .status == "R")]
    | if length > 0 then max_by(.id | tonumber).id else empty end')
  [ -n "$BUREAU_STORE_ID" ] && break
  sleep 2
done
[ -n "$BUREAU_STORE_ID" ] || fail "BureauStore did not become Ready"
log "BureauStore ID: $BUREAU_STORE_ID"

# Data Catalog is the only System Knowledge Store configured by Solve.
CATALOG_STORE_ID=$(active_store_id 'Data Catalog')
[ -n "$CATALOG_STORE_ID" ] || fail "Data Catalog store not found"
CATALOG_DESCRIPTION=$(curl -fsS --header "$AUTH" "$API/knowledgeStore/$CATALOG_STORE_ID" | jq -r '.description // ""')
CATALOG_PAYLOAD=$(jq -n --arg description "$CATALOG_DESCRIPTION" --argjson embeddingId "$EMBEDDING_ID" \
  '{name:"Data Catalog",knowledgeStoreType:"System",embeddingId:$embeddingId,enabled:true,description:$description,roles:["System Administrator"],questions:[]}')
log "Configuring Data Catalog..."
curl -fsS -X PUT --header "$AUTH" -H 'Content-Type: application/json' \
  --data "$CATALOG_PAYLOAD" "$API/knowledgeStore/$CATALOG_STORE_ID" >/dev/null
CATALOG_STORE_ID=$(active_store_id 'Data Catalog')
[ -n "$CATALOG_STORE_ID" ] || fail "Data Catalog store missing after update"
log "Data Catalog ID: $CATALOG_STORE_ID"

# Preserve original GUI-compatible narrative payload.
BUREAU_NARRATIVE_ID=$(narrative_id_for_store "$NARRATIVE_NAME" "$BUREAU_STORE_ID")
NARRATIVE_PAYLOAD=$(jq -n --arg name "$NARRATIVE_NAME" \
  --arg description "$NARRATIVE_DESCRIPTION" --arg template "$NARRATIVE_TEMPLATE" \
  --arg sql "$SQL_QUERY" --arg table "$TABLE_NAME" --argjson storeId "$BUREAU_STORE_ID" \
  '{name:$name,narrativeTemplate:$template,narrativeDescription:$description,sqlquery:$sql,mainSQLTable:$table,multirowdataset:true,batchsize:1000,maxFailedRecords:100,knowledgeStoreId:$storeId}')
if [ -z "$BUREAU_NARRATIVE_ID" ]; then
  log "Creating Bureau Data Narrative..."
  curl -fsS -X POST --header "$AUTH" -H 'Content-Type: application/json' \
    --data "$NARRATIVE_PAYLOAD" "$API/narratives" >/dev/null
else
  log "Updating Bureau Data Narrative..."
  curl -fsS -X PATCH --header "$AUTH" -H 'Content-Type: application/json' \
    --data "$NARRATIVE_PAYLOAD" "$API/narratives/$BUREAU_NARRATIVE_ID" >/dev/null
fi

BUREAU_NARRATIVE_ID=""
for i in $(seq 1 30); do
  BUREAU_NARRATIVE_ID=$(narrative_id_for_store "$NARRATIVE_NAME" "$BUREAU_STORE_ID")
  [ -n "$BUREAU_NARRATIVE_ID" ] && break
  sleep 2
done
[ -n "$BUREAU_NARRATIVE_ID" ] || fail "Bureau Data Narrative not found after creation"

CATALOG_NARRATIVE_ID=""
for i in $(seq 1 30); do
  CATALOG_NARRATIVE_ID=$(narrative_id_for_store 'Data Catalog Narrative' "$CATALOG_STORE_ID")
  [ -n "$CATALOG_NARRATIVE_ID" ] && break
  sleep 2
done
[ -n "$CATALOG_NARRATIVE_ID" ] || fail "Data Catalog Narrative not found for active store"

# Start the short narrative first, then the long-running Bureau narrative.
start_narrative "$CATALOG_NARRATIVE_ID" 'Data Catalog Narrative'
start_narrative "$BUREAU_NARRATIVE_ID" 'Bureau Data Narrative'
wait_both
