#!/bin/bash

set -euo pipefail

BASE_URL="http://localhost:8081"
AUTH="Authorization: Basic U3lzdGVtQWRtaW46c3lz"
EXPECTED_NAME="Bureau Data Assistant"

# ------------------------------------------------------------
# Get assistants
# ------------------------------------------------------------

ASSISTANTS=$(
  curl --silent --fail --location \
    "${BASE_URL}/intersystems/semantic-search/v1/assistant" \
    --header "${AUTH}"
) || fail-message "Unable to check the AI Assistants. Please make sure Data Studio is running."

# ------------------------------------------------------------
# Check 1: Bureau Data Assistant exists
# ------------------------------------------------------------

ASSISTANT_ID=$(
  echo "${ASSISTANTS}" |
    jq -r --arg name "${EXPECTED_NAME}" '
      (.assistants // .items // [])
      | .[]
      | select(.name == $name)
      | .id
    ' |
    head -1
)

if [ -z "${ASSISTANT_ID}" ] || [ "${ASSISTANT_ID}" = "null" ]; then
  fail-message "Have you created an AI Assistant named \"Bureau Data Assistant\"?"
fi

# ------------------------------------------------------------
# Get full assistant configuration
# ------------------------------------------------------------

ASSISTANT=$(
  curl --silent --fail --location \
    "${BASE_URL}/intersystems/semantic-search/v1/assistant/${ASSISTANT_ID}" \
    --header "${AUTH}"
) || fail-message "The Bureau Data Assistant was found, but its configuration could not be read."

# ------------------------------------------------------------
# Check 2: Correct name
# ------------------------------------------------------------

ASSISTANT_NAME=$(echo "${ASSISTANT}" | jq -r '.name // empty')

if [ "${ASSISTANT_NAME}" != "${EXPECTED_NAME}" ]; then
  fail-message "Please name the AI Assistant \"Bureau Data Assistant\"."
fi

# ------------------------------------------------------------
# Check 3: OpenAI vendor selected
# ------------------------------------------------------------

VENDOR_NAME=$(
  echo "${ASSISTANT}" |
    jq -r '.vendorConfig // empty'
)

if [ "${VENDOR_NAME}" != "OpenAI" ]; then
  fail-message "Please select OpenAI as the Vendor for the Bureau Data Assistant."
fi

# ------------------------------------------------------------
# Check 4: Required agents selected
# ------------------------------------------------------------

REQUIRED_AGENTS=(
  "Data Catalog"
  "Graphing"
  "BureauStore"
  "Text-to-SQL"
)

SELECTED_AGENT_NAMES=$(
  echo "${ASSISTANT}" |
    jq -r '
      (.agents // [])
      | .[]
      | if type == "object" then .name else . end
    ' |
    sort -u
)

if [ -z "${SELECTED_AGENT_NAMES}" ]; then
  fail-message "Please select the required Agents for the Bureau Data Assistant."
fi

MISSING_AGENT_NAMES=""

for AGENT_NAME in "${REQUIRED_AGENTS[@]}"; do
  if ! printf '%s\n' "${SELECTED_AGENT_NAMES}" | grep -Fxq "${AGENT_NAME}"; then
    if [ -z "${MISSING_AGENT_NAMES}" ]; then
      MISSING_AGENT_NAMES="${AGENT_NAME}"
    else
      MISSING_AGENT_NAMES="${MISSING_AGENT_NAMES}, ${AGENT_NAME}"
    fi
  fi
done

if [ -n "${MISSING_AGENT_NAMES}" ]; then
  fail-message "Please select all required Agents for the Bureau Data Assistant. Missing: ${MISSING_AGENT_NAMES}"
fi

exit 0