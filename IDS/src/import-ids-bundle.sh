#!/bin/bash

set -euo pipefail

BASE="http://localhost:8081/intersystems"
AUTH="SystemAdmin:sys"

CONFIG_ZIP="/root/sds-samples/IDS/Data/Bundle.zip"
BUNDLE_NAME="Bundle.zip"

BUNDLE_IMPORT="/tmp/bundleimport.json"
BUNDLE_SAVE="/tmp/bundlesave.json"
BUNDLE_RESPONSE="/tmp/bundlesave-response.json"

MARKER="/root/sds-samples/IDS/Data/.ids-bundle-imported"

# ------------------------------------------------------------
# 1. Wait for IDS API to become available
# ------------------------------------------------------------

echo "Waiting for IDS API..."

READY=false

for i in $(seq 1 180); do

  if curl -sf -u "$AUTH" \
    "$BASE/semantic-search/v1/vendor" \
    >/dev/null 2>&1; then
    READY=true
    break
  fi

  sleep 5

done

if [ "$READY" != "true" ]; then
  echo "ERROR: IDS API did not become available."
  exit 1
fi

echo "IDS API is available."

# ------------------------------------------------------------
# 2. Check whether the bundle was previously imported
# ------------------------------------------------------------

if [ -f "$MARKER" ]; then
  echo "IDS bundle was previously imported. Skipping."
  exit 0
fi

# ------------------------------------------------------------
# 3. Verify that Bundle.zip exists
# ------------------------------------------------------------

if [ ! -f "$CONFIG_ZIP" ]; then
  echo "ERROR: Missing configuration bundle: $CONFIG_ZIP"
  exit 1
fi

# ------------------------------------------------------------
# 4. Upload Bundle.zip
# ------------------------------------------------------------

echo "Uploading ${BUNDLE_NAME}..."

curl -fsS -u "$AUTH" \
  -X POST \
  "$BASE/ccm/v1/import" \
  -F "file=@${CONFIG_ZIP};type=application/zip" \
  -F "fileName=${BUNDLE_NAME}" \
  >/dev/null

echo "Bundle uploaded successfully."

# ------------------------------------------------------------
# 5. Analyze the bundle
# ------------------------------------------------------------

echo "Analyzing ${BUNDLE_NAME}..."

curl -fsS -u "$AUTH" \
  "$BASE/ccm/v1/import/${BUNDLE_NAME}" \
  -o "$BUNDLE_IMPORT"

# Verify that configurations were found
if ! jq -e '
  (.items | type == "array") and
  (.items | length > 0)
' "$BUNDLE_IMPORT" >/dev/null; then
  echo "ERROR: No configurations found in the bundle."
  exit 1
fi

echo "Bundle analysis completed."

# ------------------------------------------------------------
# 6. Convert import list into bundleSave payload
# ------------------------------------------------------------

jq '{items: [.items[] | {fileName}]}' \
  "$BUNDLE_IMPORT" \
  > "$BUNDLE_SAVE"

echo "Prepared configuration import payload."

# ------------------------------------------------------------
# 7. Import configurations into IDS
# ------------------------------------------------------------

echo "Importing configurations into IDS..."

curl -fsS -u "$AUTH" \
  -X PUT \
  "$BASE/ccm/v1/import" \
  -H 'Content-Type: application/json' \
  -d @"$BUNDLE_SAVE" \
  -o "$BUNDLE_RESPONSE"

# Verify that the API returned a configuration list
if ! jq -e '
  (.items | type == "array") and
  (.items | length > 0)
' "$BUNDLE_RESPONSE" >/dev/null; then
  echo "ERROR: IDS did not return a valid import result."
  cat "$BUNDLE_RESPONSE"
  exit 1
fi

# ------------------------------------------------------------
# 8. Mark the bundle as successfully imported
# ------------------------------------------------------------

touch "$MARKER"

echo "IDS bundle import completed successfully."