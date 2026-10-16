#!/bin/bash

set -euo pipefail

CONTAINER="ids-business360-iris-1"
CSV_HOST="/root/sds-samples/IDS/Data/bureau.csv"
CSV_CONTAINER="/tmp/bureau.csv"
NAMESPACE="B360"

# ------------------------------------------------------------
# 1. Verify that the CSV file exists
# ------------------------------------------------------------

if [ ! -f "$CSV_HOST" ]; then
  echo "ERROR: CSV file not found: $CSV_HOST"
  exit 1
fi

# ------------------------------------------------------------
# 2. Wait for the IRIS container to be ready
# ------------------------------------------------------------

echo "Waiting for IRIS..."

READY=false

for i in $(seq 1 180); do
  if docker exec "$CONTAINER" \
    iris session IRIS -U "$NAMESPACE" \
    'write "READY",!' 2>/dev/null | grep -q "READY"; then
    READY=true
    break
  fi

  sleep 5
done

if [ "$READY" != "true" ]; then
  echo "ERROR: IRIS did not become ready."
  exit 1
fi

# ------------------------------------------------------------
# 3. Check whether Sample.BureauData already contains records
# ------------------------------------------------------------

echo "Checking Sample.BureauData..."

COUNT=$(
  printf 'set r=##class(%%SQL.Statement).%%ExecDirect(,"SELECT COUNT(*) AS Cnt FROM Sample.BureauData")\nif r.%%Next() write "ROWCOUNT=",r.%%Get("Cnt"),!\nhalt\n' |
    docker exec -i "$CONTAINER" iris session IRIS -U "$NAMESPACE" |
    sed -n 's/.*ROWCOUNT=\([0-9][0-9]*\).*/\1/p' |
    tail -1
)

if [ -z "$COUNT" ]; then
  echo "ERROR: Could not query Sample.BureauData. Check that the bundle import created the table."
  exit 1
fi

echo "Current row count: $COUNT"

if [ "$COUNT" -gt 0 ]; then
  echo "Sample.BureauData already contains data. Skipping CSV import."
  exit 0
fi

# ------------------------------------------------------------
# 4. Copy the CSV into the IRIS container
# ------------------------------------------------------------

echo "Copying bureau.csv into IRIS..."

docker cp "$CSV_HOST" "$CONTAINER:$CSV_CONTAINER"

# ------------------------------------------------------------
# 5. Load the CSV into Sample.BureauData
#
# Explicitly specify the 17 business columns to exclude
# %irisrowid and %batchid from the CSV mapping.
# ------------------------------------------------------------

echo "Loading Bureau data..."

LOAD_OUTPUT=$(
  printf 'set sql="LOAD DATA FROM FILE '\''/tmp/bureau.csv'\'' INTO Sample.BureauData (SK_ID_CURR,ID,CREDIT_ACTIVE,CREDIT_CURRENCY,DAYS_CREDIT,CREDIT_DAY_OVERDUE,DAYS_CREDIT_ENDDATE,DAYS_ENDDATE_FACT,AMT_CREDIT_MAX_OVERDUE,CNT_CREDIT_PROLONG,AMT_CREDIT_SUM,AMT_CREDIT_SUM_DEBT,AMT_CREDIT_SUM_LIMIT,AMT_CREDIT_SUM_OVERDUE,CREDIT_TYPE,DAYS_CREDIT_UPDATE,AMT_ANNUITY) USING {""from"":{""file"":{""header"":true}}}"\nset r=##class(%%SQL.Statement).%%ExecDirect(,sql)\nwrite "SQLCODE=",r.%%SQLCODE,!\nwrite "MESSAGE=",r.%%Message,!\nhalt\n' |
    docker exec -i "$CONTAINER" iris session IRIS -U "$NAMESPACE"
)

echo "$LOAD_OUTPUT"

# ------------------------------------------------------------
# 6. Check for SQL errors
# ------------------------------------------------------------

SQLCODE=$(
  printf '%s\n' "$LOAD_OUTPUT" |
    sed -n 's/.*SQLCODE=\(-\?[0-9][0-9]*\).*/\1/p' |
    tail -1
)

if [ -z "$SQLCODE" ] || [ "$SQLCODE" != "0" ]; then
  echo "ERROR: LOAD DATA failed. SQLCODE=${SQLCODE:-unknown}"
  exit 1
fi

# ------------------------------------------------------------
# 7. Verify that records were inserted
# ------------------------------------------------------------

NEW_COUNT=$(
  printf 'set r=##class(%%SQL.Statement).%%ExecDirect(,"SELECT COUNT(*) AS Cnt FROM Sample.BureauData")\nif r.%%Next() write "ROWCOUNT=",r.%%Get("Cnt"),!\nhalt\n' |
    docker exec -i "$CONTAINER" iris session IRIS -U "$NAMESPACE" |
    sed -n 's/.*ROWCOUNT=\([0-9][0-9]*\).*/\1/p' |
    tail -1
)

if [ -z "$NEW_COUNT" ] || [ "$NEW_COUNT" -eq 0 ]; then
  echo "ERROR: No records were found in Sample.BureauData after loading."
  exit 1
fi

echo "Bureau data loaded successfully. Total rows: $NEW_COUNT"