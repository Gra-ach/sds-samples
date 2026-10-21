#!/usr/bin/env bash
set -Eeuo pipefail

IDS_DIR="/root/sds-samples/IDS"
DATA_DIR="$IDS_DIR/Data"
LOG_FILE="/tmp/prepare-ids-host-image.log"
CONTAINER="ids-business360-iris-1"
NAMESPACE="B360"
START_TIMEOUT="${START_TIMEOUT:-900}"
API_TIMEOUT="${API_TIMEOUT:-300}"
BASE="http://localhost:8081/intersystems"
AUTH="SystemAdmin:sys"

exec > >(tee -a "$LOG_FILE") 2>&1
trap 'rc=$?; echo "ERROR: Host image preparation failed (exit $rc) at line $LINENO. Review $LOG_FILE" >&2; exit "$rc"' ERR
log() { printf '\n[%s] %s\n' "$(date -u +%FT%TZ)" "$*"; }
die() { echo "ERROR: $*" >&2; exit 1; }
require_file() { test -s "$1" || die "Missing or empty file: $1"; }

log "Checking prerequisites"
for cmd in docker curl jq git; do command -v "$cmd" >/dev/null || die "Missing command: $cmd"; done
docker compose version >/dev/null || die "Docker Compose plugin unavailable"
docker info >/dev/null || die "Docker daemon unavailable"
test -d "$IDS_DIR" || die "Missing IDS repository: $IDS_DIR"
require_file "$IDS_DIR/start.sh"
require_file "$IDS_DIR/stop.sh"
require_file "$IDS_DIR/licenses/iris.key"
require_file "$DATA_DIR/Bundle.zip"
require_file "$DATA_DIR/bureau.csv"
require_file "$DATA_DIR/import-ids-bundle.sh"
require_file "$DATA_DIR/load-bureau-data.sh"
cd "$IDS_DIR"

log "Validating Compose configuration"
docker compose -f docker-compose.yml -f docker-compose.langfuse.yml config --quiet

log "Starting IDS and Langfuse"
bash ./start.sh

# Services with no healthcheck only need to be running; those with one must be healthy.
required=(ids-business360-iris-1 semantic-search-iris ids-business360-frontend-1 semantic-search-orchestrator semantic-search-webgateway smp-webgateway ids-postgres-1 ids-clickhouse-1 ids-minio-1 ids-redis-1 ids-langfuse-web-1 ids-langfuse-worker-1)
log "Waiting for all 12 required containers (timeout ${START_TIMEOUT}s)"
deadline=$((SECONDS + START_TIMEOUT))
while :; do
  pending=()
  for name in "${required[@]}"; do
    state=$(docker inspect "$name" --format '{{.State.Status}}|{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' 2>/dev/null || true)
    case "$state" in
      running\|healthy|running\|none) ;;
      *) pending+=("$name=$state") ;;
    esac
  done
  ((${#pending[@]} == 0)) && break
  if ((SECONDS >= deadline)); then
    printf 'Unready containers: %s\n' "${pending[*]}" >&2
    docker ps -a --format 'table {{.Names}}\t{{.Status}}' || true
    docker logs --tail 80 "$CONTAINER" || true
    die "IDS startup did not finish in time"
  fi
  sleep 5
done
log "All required containers running and healthchecks passing"

log "Verifying persistent mounts"
check_mount() {
  local name="$1" dest="$2" expected_type="$3"
  docker inspect "$name" --format '{{json .Mounts}}' |
    jq -e --arg dest "$dest" --arg typ "$expected_type" 'any(.[]; .Destination == $dest and .Type == $typ and .RW == true)' >/dev/null ||
    die "Persistent $expected_type mount missing: $name:$dest"
}
check_mount ids-business360-iris-1 /volumes volume
check_mount semantic-search-iris /volumes bind
check_mount ids-postgres-1 /var/lib/postgresql/data volume
check_mount ids-clickhouse-1 /var/lib/clickhouse volume
check_mount ids-clickhouse-1 /var/log/clickhouse-server volume
check_mount ids-minio-1 /data volume

# Record volume identities to confirm they remain after stop.
volumes=()
for spec in 'ids-business360-iris-1:/volumes' 'ids-postgres-1:/var/lib/postgresql/data' 'ids-clickhouse-1:/var/lib/clickhouse' 'ids-clickhouse-1:/var/log/clickhouse-server' 'ids-minio-1:/data'; do
  name=${spec%%:*}; dest=${spec#*:}
  vol=$(docker inspect "$name" --format '{{json .Mounts}}' | jq -r --arg d "$dest" '.[] | select(.Destination == $d) | .Name // empty')
  test -n "$vol" || die "No volume name for $spec"
  volumes+=("$vol")
done

log "Waiting for IDS API (timeout ${API_TIMEOUT}s)"
deadline=$((SECONDS + API_TIMEOUT))
until curl -fsS -u "$AUTH" "$BASE/semantic-search/v1/vendor" >/dev/null 2>&1; do
  ((SECONDS < deadline)) || die "IDS API unavailable"
  sleep 5
done

log "Importing IDS bundle using existing script"
bash "$DATA_DIR/import-ids-bundle.sh"
# The import script uses a marker and may skip the import. Validate current state regardless.
log "Checking physical BureauData table"
query_count() {
  local result
  result=$(printf 'set r=##class(%%SQL.Statement).%%ExecDirect(,"SELECT COUNT(*) AS Cnt FROM Sample.BureauData")\nwrite "SQLCODE=",r.%%SQLCODE,!\nif r.%%SQLCODE=0,r.%%Next() write "ROWCOUNT=",r.%%Get("Cnt"),!\nhalt\n' |
    docker exec -i "$CONTAINER" iris session IRIS -U "$NAMESPACE") || return 1
  printf '%s\n' "$result" | grep -Eq 'SQLCODE=0' || return 1
  printf '%s\n' "$result" | sed -n 's/.*ROWCOUNT=\([0-9][0-9]*\).*/\1/p' | tail -1
}
if ! count=$(query_count) || [[ ! "$count" =~ ^[0-9]+$ ]]; then
  die "Sample.BureauData is missing or cannot be queried in namespace $NAMESPACE. Bundle metadata alone does not create the physical table. Create/publish the table or run the required promotion step before retrying."
fi
log "BureauData row count before loader: $count"

log "Running CSV loader (it must skip when data already exists)"
bash "$DATA_DIR/load-bureau-data.sh"
count=$(query_count) || die "Cannot query BureauData after CSV loader"
[[ "$count" =~ ^[0-9]+$ ]] && ((count > 0)) || die "BureauData has no rows after CSV loading"
log "BureauData contains $count rows"

log "Stopping IDS cleanly (no volume deletion)"
bash ./stop.sh

log "Checking that persistent Docker volumes remain"
for vol in "${volumes[@]}"; do
  docker volume inspect "$vol" >/dev/null || die "Volume missing after stop: $vol"
done
test -d "$IDS_DIR/semanticsearch/volumes" || die "Semantic Search bind directory missing"
log "SUCCESS: Host image is prepared and stopped. Save the image in Instruqt."
log "After publishing, test a fresh VM: start IDS and verify both IRIS databases and BureauData rows."
