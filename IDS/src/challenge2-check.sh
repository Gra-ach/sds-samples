#!/bin/bash

set -euo pipefail

BASE_URL="http://localhost:8081"
AUTH="Authorization: Basic U3lzdGVtQWRtaW46c3lz"

BUREAU_STORE_NAME="BureauStore"
BUREAU_STORE_DESCRIPTION="Credit bureau data containing customer credit accounts, including credit type and status, currency, credit amounts, outstanding debt, credit limits, overdue amounts and days, account duration, and credit prolongations. Use this Knowledge Store for questions about customers’ credit history, active or overdue accounts, debt and credit exposure, credit types and currencies, and prolonged credits."

NARRATIVE_NAME="Bureau Data Narrative"
NARRATIVE_DESCRIPTION="Narrative to get Bureau Data Info"
EXPECTED_TABLE="Sample.BureauData"
EXPECTED_SQL="SELECT * FROM Sample.BureauData WHERE ID = '{{ID}}'"

EXPECTED_TEMPLATE="Customer {{SK_ID_CURR}} has a credit bureau record {{ID}} for a {{CREDIT_TYPE}} account. The account is currently {{CREDIT_ACTIVE}} and is denominated in {{CREDIT_CURRENCY}}. The credit was granted {{DAYS_CREDIT}} days before the customer's application. It is currently {{CREDIT_DAY_OVERDUE}} days overdue, has been prolonged {{CNT_CREDIT_PROLONG}} times, and has a total credit amount of {{AMT_CREDIT_SUM}}. The outstanding debt is {{AMT_CREDIT_SUM_DEBT}}, the available credit limit is {{AMT_CREDIT_SUM_LIMIT}}, the current overdue balance is {{AMT_CREDIT_SUM_OVERDUE}}, and the maximum overdue amount ever recorded is {{AMT_CREDIT_MAX_OVERDUE}}. The credit is expected to end in {{DAYS_CREDIT_ENDDATE}} days, was actually closed after {{DAYS_ENDDATE_FACT}} days (if applicable), was last updated {{DAYS_CREDIT_UPDATE}} days before the application, and has an annuity payment amount of {{AMT_ANNUITY}}."

SYSTEM_STORES=(
  "Data Catalog"
  "Graphing"
  "Text-to-SQL"
  "Text-to-SQL Column Value Index"
)

PROCESSED_SYSTEM_STORES=(
  "Data Catalog"
  "Text-to-SQL"
  "Text-to-SQL Column Value Index"
)

# ------------------------------------------------------------
# Get Knowledge Stores
# ------------------------------------------------------------

KNOWLEDGE_STORES=$(
  curl --silent --fail --location \
    "${BASE_URL}/intersystems/semantic-search/v1/knowledgeStore" \
    --header "${AUTH}"
) || fail-message "Unable to check Knowledge Stores. Please make sure Data Studio is running."

# ------------------------------------------------------------
# Get configured OpenAI embedding
# ------------------------------------------------------------

EMBEDDINGS=$(
  curl --silent --fail --location \
    "${BASE_URL}/intersystems/semantic-search/v1/embedding?configuredOnly=true" \
    --header "${AUTH}"
) || fail-message "Unable to retrieve the configured embedding models."

EMBEDDING_ID=$(
  echo "${EMBEDDINGS}" |
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

if [ -z "${EMBEDDING_ID}" ]; then
  fail-message "The text-embedding-3-small (OpenAI) embedding model is not available. Please make sure OpenAI is configured."
fi

# ------------------------------------------------------------
# Get all available user roles
# ------------------------------------------------------------

ALL_ROLES=$(
  echo "${KNOWLEDGE_STORES}" |
    jq -r '
      (.availableRoles // [])[]
      | .roleName
    ' |
    sort -u
)

# ------------------------------------------------------------
# Check 1: BureauStore exists
# ------------------------------------------------------------

BUREAU_STORE_ID=$(
  echo "${KNOWLEDGE_STORES}" |
    jq -r --arg name "${BUREAU_STORE_NAME}" '
      first(
        (.knowledgeStores // [])[]
        | select(.name == $name)
        | .id
      ) // empty
    '
)

if [ -z "${BUREAU_STORE_ID}" ]; then
  fail-message "Have you created the SQL Knowledge Store named \"BureauStore\"?"
fi

# ------------------------------------------------------------
# Get full BureauStore configuration
# ------------------------------------------------------------

BUREAU_STORE=$(
  curl --silent --fail --location \
    "${BASE_URL}/intersystems/semantic-search/v1/knowledgeStore/${BUREAU_STORE_ID}" \
    --header "${AUTH}"
) || fail-message "BureauStore was found, but its configuration could not be read."


# ------------------------------------------------------------
# Check 3: BureauStore is enabled
# ------------------------------------------------------------

STORE_ENABLED=$(echo "${BUREAU_STORE}" | jq -r '.enabled // false')

if [ "${STORE_ENABLED}" != "true" ]; then
  fail-message "Please enable BureauStore."
fi

# ------------------------------------------------------------
# Check 5: Correct OpenAI embedding model
# ------------------------------------------------------------

STORE_EMBEDDING_ID=$(echo "${BUREAU_STORE}" | jq -r '.embedding.id // empty')

if [ "${STORE_EMBEDDING_ID}" != "${EMBEDDING_ID}" ]; then
  fail-message "Please select text-embedding-3-small (OpenAI) as the Embedding Model for BureauStore."
fi

# ------------------------------------------------------------
# Check 6: Select All User Roles for BureauStore
# ------------------------------------------------------------

STORE_ROLES=$(
  echo "${BUREAU_STORE}" |
    jq -r '(.roles // [])[]' |
    sort -u
)

MISSING_ROLES=$(
  comm -23 \
    <(printf '%s\n' "${ALL_ROLES}" | sed '/^$/d' | sort -u) \
    <(printf '%s\n' "${STORE_ROLES}" | sed '/^$/d' | sort -u)
)

if [ -n "${MISSING_ROLES}" ]; then
  fail-message "Please choose Select All under User Roles for BureauStore."
fi

# ------------------------------------------------------------
# Get Narratives
# ------------------------------------------------------------

NARRATIVES=$(
  curl --silent --fail --location \
    "${BASE_URL}/intersystems/semantic-search/v1/narratives" \
    --header "${AUTH}"
) || fail-message "Unable to retrieve Narratives."

# ------------------------------------------------------------
# Check 7: Bureau Data Narrative exists inside BureauStore
# ------------------------------------------------------------

NARRATIVE_ID=$(
  echo "${NARRATIVES}" |
    jq -r \
      --arg name "${NARRATIVE_NAME}" \
      --argjson storeId "${BUREAU_STORE_ID}" '
        first(
          (.items // [])[]
          | select(
              .name == $name
              and .knowledgeStoreId == $storeId
            )
          | .id
        ) // empty
      '
)

if [ -z "${NARRATIVE_ID}" ]; then
  fail-message "Have you created the \"Bureau Data Narrative\" inside BureauStore?"
fi

# ------------------------------------------------------------
# Get full Narrative configuration
# ------------------------------------------------------------

NARRATIVE=$(
  curl --silent --fail --location \
    "${BASE_URL}/intersystems/semantic-search/v1/narratives/${NARRATIVE_ID}" \
    --header "${AUTH}"
) || fail-message "Bureau Data Narrative was found, but its configuration could not be read."

# ------------------------------------------------------------
# Check 8: Narrative description
# ------------------------------------------------------------

VALUE=$(echo "${NARRATIVE}" | jq -r '.narrativeDescription // empty')

if [ "${VALUE}" != "${NARRATIVE_DESCRIPTION}" ]; then
  fail-message "Please set the exact Narrative description provided because it influences the end result to \"Narrative to get Bureau Data Info\"."
fi

# ------------------------------------------------------------
# Check 9: Table Name
# ------------------------------------------------------------

VALUE=$(echo "${NARRATIVE}" | jq -r '.mainSQLTable // empty')

if [ "${VALUE}" != "${EXPECTED_TABLE}" ]; then
  fail-message "Please set the Narrative Table Name to Sample.BureauData."
fi

# ------------------------------------------------------------
# Check 10: SQL Query
# Ignore harmless whitespace differences
# ------------------------------------------------------------

ACTUAL_SQL=$(
  echo "${NARRATIVE}" |
    jq -r '.sqlquery // empty' |
    tr '[:upper:]' '[:lower:]' |
    tr '\n\t' '  ' |
    tr -s ' ' |
    sed 's/^ *//;s/ *$//'
)

NORMALIZED_EXPECTED_SQL=$(
  printf '%s' "${EXPECTED_SQL}" |
    tr '[:upper:]' '[:lower:]' |
    tr '\n\t' '  ' |
    tr -s ' ' |
    sed 's/^ *//;s/ *$//'
)

if [ "${ACTUAL_SQL}" != "${NORMALIZED_EXPECTED_SQL}" ]; then
  fail-message "Please use the SQL Query: select * from Sample.BureauData where ID = '{{ID}}'"
fi

# ------------------------------------------------------------
# Check 11: Narrative Template
# ------------------------------------------------------------

ACTUAL_TEMPLATE=$(echo "${NARRATIVE}" | jq -r '.narrativeTemplate // empty')

if [ "${ACTUAL_TEMPLATE}" != "${EXPECTED_TEMPLATE}" ]; then
  fail-message "Please use the Narrative Template provided in the challenge instructions."
fi

# ------------------------------------------------------------
# Check 12: Max Failed Records
# ------------------------------------------------------------

MAX_FAILED=$(echo "${NARRATIVE}" | jq -r '.maxFailedRecords // empty')

if [ "${MAX_FAILED}" != "100" ]; then
  fail-message "Please set Max Failed Records to 100 for Bureau Data Narrative."
fi

# ------------------------------------------------------------
# Check 13: Bureau Data Narrative processing is Ready
#
# Status is returned by GET /narratives, not the detail endpoint.
# ------------------------------------------------------------

BUREAU_STATUS=$(
  echo "${NARRATIVES}" |
    jq -r --arg id "${NARRATIVE_ID}" '
      first(
        (.items // [])[]
        | select((.id | tostring) == $id)
        | .status.processingStatus
      ) // empty
    '
)

if [ "$(echo "${BUREAU_STATUS}" | tr '[:upper:]' '[:lower:]')" != "tr" ]; then
  fail-message "Please start processing Bureau Data Narrative and wait until its status changes to Ready."
fi

# ------------------------------------------------------------
# Check 14-17:
# Required System Knowledge Stores
#
# Each must:
# - exist
# - be enabled
# - use OpenAI text-embedding-3-small
# - have Select All roles
# ------------------------------------------------------------

for STORE_NAME in "${SYSTEM_STORES[@]}"; do

  STORE_ID=$(
    echo "${KNOWLEDGE_STORES}" |
      jq -r --arg name "${STORE_NAME}" '
        first(
          (.knowledgeStores // [])[]
          | select(.name == $name)
          | .id
        ) // empty
      '
  )

  if [ -z "${STORE_ID}" ]; then
    fail-message "The ${STORE_NAME} System Knowledge Store could not be found."
  fi

  STORE=$(
    curl --silent --fail --location \
      "${BASE_URL}/intersystems/semantic-search/v1/knowledgeStore/${STORE_ID}" \
      --header "${AUTH}"
  ) || fail-message "The ${STORE_NAME} Knowledge Store could not be read."

  ENABLED=$(echo "${STORE}" | jq -r '.enabled // false')

  if [ "${ENABLED}" != "true" ]; then
    fail-message "Please enable the ${STORE_NAME} System Knowledge Store."
  fi

  SYSTEM_EMBEDDING_ID=$(echo "${STORE}" | jq -r '.embedding.id // empty')

  if [ "${SYSTEM_EMBEDDING_ID}" != "${EMBEDDING_ID}" ]; then
    fail-message "Please select text-embedding-3-small (OpenAI) as the Embedding Model for ${STORE_NAME}."
  fi

  SYSTEM_ROLES=$(
    echo "${STORE}" |
      jq -r '(.roles // [])[]' |
      sort -u
  )

  MISSING_SYSTEM_ROLES=$(
    comm -23 \
      <(printf '%s\n' "${ALL_ROLES}" | sed '/^$/d' | sort -u) \
      <(printf '%s\n' "${SYSTEM_ROLES}" | sed '/^$/d' | sort -u)
  )

  if [ -n "${MISSING_SYSTEM_ROLES}" ]; then
    fail-message "Please choose Select All under User Roles for the ${STORE_NAME} Knowledge Store."
  fi

done

# ------------------------------------------------------------
# Check processing for the 3 System Knowledge Stores
#
# Graphing does not need Start Processing.
# ------------------------------------------------------------

for STORE_NAME in "${PROCESSED_SYSTEM_STORES[@]}"; do

  STORE_ID=$(
    echo "${KNOWLEDGE_STORES}" |
      jq -r --arg name "${STORE_NAME}" '
        first(
          (.knowledgeStores // [])[]
          | select(.name == $name)
          | .id
        ) // empty
      '
  )

  STORE_NARRATIVE_COUNT=$(
    echo "${NARRATIVES}" |
      jq \
        --argjson storeId "${STORE_ID}" '
          [
            (.items // [])[]
            | select(.knowledgeStoreId == $storeId)
          ]
          | length
        '
  )

  if [ "${STORE_NARRATIVE_COUNT}" -eq 0 ]; then
    fail-message "No processing item was found for the ${STORE_NAME} Knowledge Store."
  fi

  NOT_READY_COUNT=$(
    echo "${NARRATIVES}" |
      jq \
        --argjson storeId "${STORE_ID}" '
          [
            (.items // [])[]
            | select(.knowledgeStoreId == $storeId)
            | select(
                ((.status.processingStatus // "") | ascii_downcase) != "tr"
              )
          ]
          | length
        '
  )

  if [ "${NOT_READY_COUNT}" -gt 0 ]; then
    fail-message "Please start processing the ${STORE_NAME} Knowledge Store and wait until its status changes to Ready."
  fi

done

exit 0
