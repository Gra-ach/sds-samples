#!/bin/bash

exec > >(tee /tmp/solve-challenge-3.log) 2>&1
set -euxo pipefail

BASE_URL="http://localhost:8081"
AUTH="Authorization: Basic U3lzdGVtQWRtaW46c3lz"

ASSISTANT_NAME="Bureau Data Assistant"

# ------------------------------------------------------------
# Wait until Semantic Search API is available
# ------------------------------------------------------------

until curl --silent --fail \
  "${BASE_URL}/intersystems/semantic-search/v1/vendor" \
  --header "${AUTH}" \
  >/dev/null 2>&1
do
  sleep 5
done

# ------------------------------------------------------------
# Get OpenAI vendor ID
# ------------------------------------------------------------

VENDOR_ID=$(
  curl --silent --fail --location \
    "${BASE_URL}/intersystems/semantic-search/v1/vendor?configuredOnly=true" \
    --header "${AUTH}" \
  | jq -r '
      first(
        (.vendors // [])[]
        | select(.name == "OpenAI")
        | .id
      ) // empty
    '
)

if [ -z "${VENDOR_ID}" ]; then
  echo "ERROR: Configured OpenAI vendor was not found."
  exit 1
fi

# ------------------------------------------------------------
# Get available agents
# ------------------------------------------------------------

AVAILABLE_AGENTS=$(
  curl --silent --fail --location \
    "${BASE_URL}/intersystems/semantic-search/v1/agent" \
    --header "${AUTH}"
)

# ------------------------------------------------------------
# Get ONLY the four required OpenAI agents
#
# vendorId is essential because IDS returns one copy of
# Data Catalog / Graphing / Text-to-SQL / custom stores
# for each configured vendor.
# ------------------------------------------------------------

AGENT_IDS=$(
  echo "${AVAILABLE_AGENTS}" |
    jq -c --argjson vendorId "${VENDOR_ID}" '
      [
        (.agents // .items // [])[]
        | select(
            .vendorId == $vendorId
            and (
              .name == "Data Catalog"
              or .name == "Graphing"
              or .name == "Text-to-SQL"
              or .name == "BureauStore"
            )
          )
        | .id
      ]
    '
)

# ------------------------------------------------------------
# Verify that all four required agents were found
# ------------------------------------------------------------

AGENT_COUNT=$(echo "${AGENT_IDS}" | jq 'length')

if [ "${AGENT_COUNT}" -ne 4 ]; then

  echo "ERROR: Expected 4 OpenAI agents, but found ${AGENT_COUNT}."

  echo "${AVAILABLE_AGENTS}" |
    jq -r --argjson vendorId "${VENDOR_ID}" '
      (.agents // .items // [])[]
      | select(.vendorId == $vendorId)
      | "\(.id): \(.name)"
    '

  exit 1
fi

# ------------------------------------------------------------
# Get all assignable roles
#
# Do not rely on GET /assistant for this because it can return
# {} when no assistants have been created yet.
#
# knowledgeStore returns availableRoles independently.
# ------------------------------------------------------------

KNOWLEDGE_STORES=$(
  curl --silent --fail --location \
    "${BASE_URL}/intersystems/semantic-search/v1/knowledgeStore" \
    --header "${AUTH}"
)

ROLE_NAMES=$(
  echo "${KNOWLEDGE_STORES}" |
    jq -c '
      [
        (.availableRoles // [])[]
        | .roleName
      ]
    '
)

# ------------------------------------------------------------
# Check whether Bureau Data Assistant already exists
# ------------------------------------------------------------

ASSISTANT_LIST=$(
  curl --silent --fail --location \
    "${BASE_URL}/intersystems/semantic-search/v1/assistant" \
    --header "${AUTH}"
)

ASSISTANT_ID=$(
  echo "${ASSISTANT_LIST}" |
    jq -r --arg name "${ASSISTANT_NAME}" '
      first(
        (.assistants // .items // [])[]
        | select(.name == $name)
        | .id
      ) // empty
    '
)

# ------------------------------------------------------------
# Create assistant if it does not exist
# ------------------------------------------------------------

if [ -z "${ASSISTANT_ID}" ]; then

  CREATE_PAYLOAD=$(
    jq -n \
      --arg name "${ASSISTANT_NAME}" \
      --argjson vendorId "${VENDOR_ID}" \
      --argjson roles "${ROLE_NAMES}" \
      --argjson agentIds "${AGENT_IDS}" '
        {
          name: $name,
          vendorId: $vendorId,
          roles: $roles,
          agentIds: $agentIds
        }
      '
  )

  CREATE_RESPONSE=$(
    curl --silent --fail --location \
      --request POST \
      "${BASE_URL}/intersystems/semantic-search/v1/assistant" \
      --header "${AUTH}" \
      --header 'Content-Type: application/json' \
      --data "${CREATE_PAYLOAD}"
  )

  ASSISTANT_ID=$(
    echo "${CREATE_RESPONSE}" |
      jq -r '.id // empty'
  )

  # Some API responses may not return the new ID directly
  if [ -z "${ASSISTANT_ID}" ]; then

    ASSISTANT_LIST=$(
      curl --silent --fail --location \
        "${BASE_URL}/intersystems/semantic-search/v1/assistant" \
        --header "${AUTH}"
    )

    ASSISTANT_ID=$(
      echo "${ASSISTANT_LIST}" |
        jq -r --arg name "${ASSISTANT_NAME}" '
          first(
            (.assistants // .items // [])[]
            | select(.name == $name)
            | .id
          ) // empty
        '
    )

  fi

fi

if [ -z "${ASSISTANT_ID}" ]; then
  echo "ERROR: Bureau Data Assistant could not be created."
  exit 1
fi

# ------------------------------------------------------------
# Update/fix the Assistant configuration
#
# This makes Solve idempotent:
# - correct name
# - OpenAI
# - all roles
# - exactly the four required OpenAI agents
# - enabled
# ------------------------------------------------------------

UPDATE_PAYLOAD=$(
  jq -n \
    --arg name "${ASSISTANT_NAME}" \
    --argjson vendorId "${VENDOR_ID}" \
    --argjson roles "${ROLE_NAMES}" \
    --argjson agentIds "${AGENT_IDS}" '
      {
        name: $name,
        vendorId: $vendorId,
        roles: $roles,
        agentIds: $agentIds,
        enabled: true
      }
    '
)

curl --silent --fail --location \
  --request PATCH \
  "${BASE_URL}/intersystems/semantic-search/v1/assistant/${ASSISTANT_ID}" \
  --header "${AUTH}" \
  --header 'Content-Type: application/json' \
  --data "${UPDATE_PAYLOAD}" \
  >/dev/null

# ------------------------------------------------------------
# Final verification
# ------------------------------------------------------------

ASSISTANT=$(
  curl --silent --fail --location \
    "${BASE_URL}/intersystems/semantic-search/v1/assistant/${ASSISTANT_ID}" \
    --header "${AUTH}"
)

FINAL_NAME=$(echo "${ASSISTANT}" | jq -r '.name // empty')
FINAL_VENDOR=$(echo "${ASSISTANT}" | jq -r '.vendorConfig // empty')

if [ "${FINAL_NAME}" != "${ASSISTANT_NAME}" ]; then
  echo "ERROR: Assistant name was not configured correctly."
  exit 1
fi

if [ "${FINAL_VENDOR}" != "OpenAI" ]; then
  echo "ERROR: OpenAI was not configured as the Assistant vendor."
  exit 1
fi

FINAL_AGENTS=$(
  echo "${ASSISTANT}" |
    jq -r '.agents[]?.name' |
    sort -u
)

for REQUIRED_AGENT in \
  "Data Catalog" \
  "Graphing" \
  "BureauStore" \
  "Text-to-SQL"
do
  if ! printf '%s\n' "${FINAL_AGENTS}" | grep -Fxq "${REQUIRED_AGENT}"; then
    echo "ERROR: Required agent '${REQUIRED_AGENT}' is missing."
    exit 1
  fi
done

exit 0