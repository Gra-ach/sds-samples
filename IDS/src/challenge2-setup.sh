
#!/bin/bash

set -euo pipefail

exec > /tmp/setup-challenge-2.log 2>&1

BASE="http://localhost:8081/intersystems"
AUTH="SystemAdmin:sys"
OPENAI_API_KEY="${OpenAI_Key}"

API="$BASE/semantic-search/v1"

until curl -sf -u "$AUTH" "$BASE/semantic-search/v1/vendor" >/dev/null 2>&1; do
  sleep 5
done

[ -n "$OPENAI_API_KEY" ] || exit 1

VENDOR_ID=$(curl -s -u "$AUTH" "$BASE/semantic-search/v1/vendor" | jq -r '.vendors[] | select(.name=="OpenAI") | .id' | head -1)

[ -n "$VENDOR_ID" ] && [ "$VENDOR_ID" != "null" ] || exit 1

PAYLOAD=$(jq -n --arg k "$OPENAI_API_KEY" '{vendorConfigModelData: ({vendorSpecificData:{apiKey:$k},vectorDBData:{jdbcHost:"semantic-search-iris",jdbcPort:"1972",namespace:"VECTORDB",user:"SuperUser",password:"SYS"},langfuseData:{}} | tostring)}')

STATUS_CODE=$(curl -s -o /tmp/vendor-response.json -w "%{http_code}" -u "$AUTH" -X POST "$BASE/semantic-search/v1/vendorConfig/$VENDOR_ID" -H 'Content-Type: application/json' -d "$PAYLOAD")

if [ "$STATUS_CODE" -lt 200 ] || [ "$STATUS_CODE" -ge 300 ]; then
  STATUS_CODE=$(curl -s -o /tmp/vendor-response.json -w "%{http_code}" -u "$AUTH" -X PUT "$BASE/semantic-search/v1/vendorConfig/$VENDOR_ID" -H 'Content-Type: application/json' -d "$PAYLOAD")
fi

[ "$STATUS_CODE" -ge 200 ] && [ "$STATUS_CODE" -lt 300 ] || exit 1

for i in $(seq 1 60); do
  TEST_STATUS=$(curl -s -u "$AUTH" "$BASE/semantic-search/v1/vendorConfig/$VENDOR_ID" | jq -r '.lastTestStatus // empty')

  [ -n "$TEST_STATUS" ] && [ "$TEST_STATUS" != "Testing" ] && break

  sleep 5
done

[ -n "$TEST_STATUS" ] && [ "$TEST_STATUS" != "Testing" ] || exit 1

# ------------------------------------------------------------
# 6. Find OpenAI embedding model
# ------------------------------------------------------------

echo "Finding OpenAI embedding model..."

EMBEDDING_ID=$(
  curl -fsS -u "$AUTH" \
    "$API/embedding?configuredOnly=true" |
  jq -r '
    first(
      (.embeddings // [])[]
      | select(
          .name == "text-embedding-3-small"
          and .vendorName == "OpenAI"
        )
      | .id
    ) // empty
  '
)

if [ -z "$EMBEDDING_ID" ]; then
  echo "ERROR: OpenAI text-embedding-3-small was not found."
  exit 1
fi

echo "Embedding model ID: $EMBEDDING_ID"

# ------------------------------------------------------------
# 7. Configure required System Knowledge Stores
#
# Data Catalog is intentionally excluded.
# ------------------------------------------------------------

SYSTEM_STORES=(
  "Text-to-SQL"
  "Text-to-SQL Column Value Index"
  "Graphing"
)

for STORE_NAME in "${SYSTEM_STORES[@]}"; do

  echo "Configuring Knowledge Store: $STORE_NAME"

  KNOWLEDGE_STORES=$(
    curl -fsS -u "$AUTH" \
      "$API/knowledgeStore"
  )

  STORE_ID=$(
    echo "$KNOWLEDGE_STORES" |
    jq -r --arg name "$STORE_NAME" '
      [
        (.knowledgeStores // [])[]
        | select(
            .name == $name
            and .status != "D"
        )
      ]
      | if length > 0
        then max_by(.id | tonumber).id
        else empty
        end
    '
  )

  if [ -z "$STORE_ID" ]; then
    echo "ERROR: Knowledge Store not found: $STORE_NAME"
    exit 1
  fi

  STORE=$(
    curl -fsS -u "$AUTH" \
      "$API/knowledgeStore/$STORE_ID"
  )

  DESCRIPTION=$(
    echo "$STORE" |
    jq -r '.description // ""'
  )

  STORE_PAYLOAD=$(
    jq -n \
      --arg name "$STORE_NAME" \
      --arg description "$DESCRIPTION" \
      --argjson embeddingId "$EMBEDDING_ID" '
      {
        name: $name,
        knowledgeStoreType: "System",
        embeddingId: $embeddingId,
        enabled: true,
        description: $description,
        roles: ["System Administrator"],
        questions: []
      }
    '
  )

  curl -fsS -u "$AUTH" \
    -X PUT \
    "$API/knowledgeStore/$STORE_ID" \
    -H 'Content-Type: application/json' \
    -d "$STORE_PAYLOAD" \
    >/dev/null

  echo "$STORE_NAME configuration submitted."

done

# ------------------------------------------------------------
# 8. Verify Knowledge Stores are enabled
# ------------------------------------------------------------

echo "Verifying Knowledge Store configuration..."

for STORE_NAME in "${SYSTEM_STORES[@]}"; do

  STORE_ENABLED=$(
    curl -fsS -u "$AUTH" "$API/knowledgeStore" |
    jq -r --arg name "$STORE_NAME" '
      [
        (.knowledgeStores // [])[]
        | select(
            .name == $name
            and .status != "D"
        )
      ]
      | max_by(.id | tonumber)
      | .enabled // false
    '
  )

  if [ "$STORE_ENABLED" != "true" ]; then
    echo "ERROR: $STORE_NAME is not enabled."
    exit 1
  fi

  echo "$STORE_NAME is enabled."

done

echo "Waiting for Knowledge Store configuration to settle..."
sleep 10

# ------------------------------------------------------------
# 9. Start and verify System narrative processing
#
# Graphing does not require narrative processing.
# ------------------------------------------------------------

PROCESS_STORES=(
  "Text-to-SQL"
  "Text-to-SQL Column Value Index"
)

for STORE_NAME in "${PROCESS_STORES[@]}"; do

  echo "Processing $STORE_NAME..."

  # Retrieve current Knowledge Store ID

  STORE_ID=$(
    curl -fsS -u "$AUTH" \
      "$API/knowledgeStore" |
    jq -r --arg name "$STORE_NAME" '
      [
        (.knowledgeStores // [])[]
        | select(
            .name == $name
            and .status != "D"
        )
      ]
      | if length > 0
        then max_by(.id | tonumber).id
        else empty
        end
    '
  )

  if [ -z "$STORE_ID" ]; then
    echo "ERROR: Active Knowledge Store not found: $STORE_NAME"
    exit 1
  fi

  echo "$STORE_NAME active ID: $STORE_ID"

  # Retrieve current narrative IDs

  NARRATIVE_IDS=$(
    curl -fsS -u "$AUTH" \
      "$API/narratives" |
    jq -r --arg storeId "$STORE_ID" '
      (.items // [])[]
      | select(
          (.knowledgeStoreId | tostring) == $storeId
        )
      | .id
    '
  )

  if [ -z "$NARRATIVE_IDS" ]; then
    echo "ERROR: No narratives found for $STORE_NAME"
    exit 1
  fi

  while IFS= read -r NARRATIVE_ID; do

    [ -n "$NARRATIVE_ID" ] || continue

    echo "Starting narrative $NARRATIVE_ID for $STORE_NAME..."

    # Always send Start Processing.
    # This also handles narratives in ST (Paused).

    # Start processing with retries

  STARTED=false

  for attempt in $(seq 1 12); do

   echo "Starting narrative $NARRATIVE_ID (attempt $attempt)..."

   HTTP_CODE=$(
    curl -sS \
      -o /tmp/narrative-start-response.json \
      -w "%{http_code}" \
      -u "$AUTH" \
      -X PUT \
      "$API/narratives/$NARRATIVE_ID/processing?shouldStart=true"
    )

    if [ "$HTTP_CODE" -ge 200 ] &&
     [ "$HTTP_CODE" -lt 300 ]; then

      STARTED=true
     echo "Processing request accepted."
      break
    fi

    echo "Attempt $attempt returned HTTP $HTTP_CODE."

   sleep 5

  done

  if [ "$STARTED" != "true" ]; then
   echo "ERROR: Unable to start narrative $NARRATIVE_ID."
   cat /tmp/narrative-start-response.json
   exit 1
  fi

    # --------------------------------------------------------
    # 10. Wait until narrative reaches Ready (TR)
    # --------------------------------------------------------

    echo "Waiting for narrative $NARRATIVE_ID..."

    READY=false
    NARRATIVE_STATUS=""

    for i in $(seq 1 60); do

      NARRATIVE_STATUS=$(
        curl -fsS -u "$AUTH" \
          "$API/narratives" |
        jq -r --arg id "$NARRATIVE_ID" '
          first(
            (.items // [])[]
            | select((.id | tostring) == $id)
            | .status.processingStatus
          ) // empty
        '
      )

      echo "$STORE_NAME narrative status: $NARRATIVE_STATUS"

      if [ "$NARRATIVE_STATUS" = "TR" ]; then
        READY=true
        break
      fi

      sleep 5

    done

    if [ "$READY" != "true" ]; then
      echo "ERROR: $STORE_NAME narrative did not become Ready."
      echo "Last processing status: $NARRATIVE_STATUS"
      exit 1
    fi

    echo "$STORE_NAME narrative $NARRATIVE_ID is Ready."

  done <<< "$NARRATIVE_IDS"

done

# ------------------------------------------------------------
# 11. Final verification
# ------------------------------------------------------------

echo "Verifying final narrative statuses..."

curl -fsS -u "$AUTH" "$API/narratives" |
jq -r '
  (.items // [])[]
  | select(
      .name == "Text-to-SQL Narrative"
      or .name == "Text-to-SQL Column Value Index Narrative"
    )
  | "\(.name): \(.status.processingStatus)"
'