#!/usr/bin/env bash
# Two isolated Docker environments. Heavy exercise: run in Actions with the tested CI images.
# No cloud CLI, Kubernetes context, existing Compose project or user-owned data is touched.
set -euo pipefail
# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

require_cmd docker curl jq openssl sha256sum tar date
docker info >/dev/null 2>&1 || die 'Docker is required'
API_IMAGE="${CONTINUITY_API_IMAGE:-dx03v2-api:e2e}"
WEB_IMAGE="${CONTINUITY_WEB_IMAGE:-dx03v2-web:e2e}"
POSTGRES_IMAGE='postgres:17-alpine@sha256:b0f9560a2de083e2cc7382e75f808c7381a32852a7ec49117deedb300e552b24'
API_ID="$(docker image inspect "$API_IMAGE" --format '{{.Id}}')"
WEB_ID="$(docker image inspect "$WEB_IMAGE" --format '{{.Id}}')"
RUN_ID="dx03v2-dr-$(rand_hex 6)"
LABEL="lab.continuity.run=$RUN_ID"
REPORT_DIR="${CONTINUITY_REPORT_DIR:-${TMPDIR:-/tmp}/dx03v2-continuity}"
umask 077
WORK="$(mktemp -d "${TMPDIR:-/tmp}/dx03v2-continuity.XXXXXXXX")"
mkdir -p "$REPORT_DIR"
declare -a CONTAINERS=() NETWORKS=() VOLUMES=()
declare -A ENDPOINT=()

# Check ownership even on a failing run. Names alone are never enough for deletion.
remove_owned() {
  local kind=$1 name=$2 owner
  owner="$(docker "$kind" inspect "$name" --format '{{index .Config.Labels "lab.continuity.run"}}' 2>/dev/null)" ||
    owner="$(docker "$kind" inspect "$name" --format '{{index .Labels "lab.continuity.run"}}' 2>/dev/null)" ||
    return 1
  [[ "$owner" == "$RUN_ID" ]] || return 1
  if [[ "$kind" == container ]]; then docker container rm -f "$name" >/dev/null
  else docker "$kind" rm "$name" >/dev/null; fi
}
cleanup() {
  local rc=$? name
  trap - EXIT
  if ((rc != 0)); then
    docker container ls -a --filter "label=$LABEL" --format '{{.Names}} {{.Status}}' \
      >"$REPORT_DIR/failed-containers.txt" || rc=1
    for name in "${CONTAINERS[@]}"; do
      if docker container inspect "$name" >/dev/null 2>&1; then
        docker logs --tail 100 "$name" >"$REPORT_DIR/$name.log" 2>&1 || rc=1
      fi
    done
  fi
  for name in "${CONTAINERS[@]}"; do
    if docker container inspect "$name" >/dev/null 2>&1; then remove_owned container "$name" || rc=1; fi
  done
  for name in "${NETWORKS[@]}"; do
    if docker network inspect "$name" >/dev/null 2>&1; then remove_owned network "$name" || rc=1; fi
  done
  for name in "${VOLUMES[@]}"; do
    if docker volume inspect "$name" >/dev/null 2>&1; then remove_owned volume "$name" || rc=1; fi
  done
  [[ "$WORK" == "${TMPDIR:-/tmp}"/dx03v2-continuity.* ]] || exit 1
  rm -rf -- "${WORK:?}"
  exit "$rc"
}
trap cleanup EXIT

# A signed release and remote Terraform state have separate cloud runbooks. This bundle exercises
# recovery of the exact local image IDs, migrations, runtime configuration and application secrets.
mkdir "$WORK/bundle"
{
  printf 'POSTGRES_DB=dx03v2\nPOSTGRES_USER=dx03v2\n'
  printf 'POSTGRES_PASSWORD=%s\n' "$(rand_hex 24)"
} >"$WORK/bundle/db.env"
{
  printf 'APP_ENV=ci\nDB_HOST=db\nDB_PORT=5432\nDB_NAME=dx03v2\nDB_USER=dx03v2\n'
  sed 's/^POSTGRES_PASSWORD=/DB_PASSWORD=/' "$WORK/bundle/db.env" | grep '^DB_PASSWORD='
  printf 'DB_SSL_MODE=verify-full\nDB_SSL_CA_FILE=/tls/ca.crt\n'
  printf 'TRUST_PROXY_HOPS=1\nRATE_LIMIT_WRITE_PER_MINUTE=1000\nLOG_LEVEL=warn\n'
  printf 'ADMIN_TOKEN=%s\n' "$(rand_hex 24)"
} >"$WORK/bundle/api.env"
openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 1 \
  -keyout "$WORK/ca.key" -out "$WORK/bundle/ca.crt" -subj '/CN=continuity-drill-ca' >/dev/null 2>&1
openssl req -newkey rsa:2048 -nodes -keyout "$WORK/bundle/server.key" \
  -out "$WORK/db.csr" -subj '/CN=db' >/dev/null 2>&1
printf 'subjectAltName=DNS:db\nextendedKeyUsage=serverAuth\n' >"$WORK/extensions.cnf"
openssl x509 -req -in "$WORK/db.csr" -CA "$WORK/bundle/ca.crt" -CAkey "$WORK/ca.key" \
  -CAcreateserial -days 1 -sha256 -extfile "$WORK/extensions.cnf" \
  -out "$WORK/bundle/server.crt" >/dev/null 2>&1
printf '%s\n%s\n' "$API_ID" "$WEB_ID" >"$WORK/bundle/image-ids"
tar -czf "$WORK/recovery-bundle.tgz" -C "$WORK/bundle" .
BUNDLE_SHA="$(sha256_of "$WORK/recovery-bundle.tgz")"
rm -rf -- "$WORK/bundle"
mkdir "$WORK/bundle"
[[ "$(sha256_of "$WORK/recovery-bundle.tgz")" == "$BUNDLE_SHA" ]] || die 'configuration bundle checksum mismatch'
tar -xzf "$WORK/recovery-bundle.tgz" -C "$WORK/bundle"
[[ "$(sed -n '1p' "$WORK/bundle/image-ids")" == "$API_ID" ]] || die 'API artifact changed during recovery'
[[ "$(sed -n '2p' "$WORK/bundle/image-ids")" == "$WEB_ID" ]] || die 'web artifact changed during recovery'
# API receives only the public CA; it never mounts the database private key.
chmod 0755 "$WORK" "$WORK/bundle"
chmod 0644 "$WORK/bundle/ca.crt"

new_volume() {
  local name=$1
  docker volume create --label "$LABEL" "$name" >/dev/null
  VOLUMES+=("$name")
}
new_region() {
  local region=$1 helper="$RUN_ID-$1-seed"
  docker network create --internal --label "$LABEL" "$RUN_ID-$region-backend" >/dev/null
  NETWORKS+=("$RUN_ID-$region-backend")
  docker network create --label "$LABEL" "$RUN_ID-$region-frontend" >/dev/null
  NETWORKS+=("$RUN_ID-$region-frontend")
  new_volume "$RUN_ID-$region-data"
  new_volume "$RUN_ID-$region-tls"
  CONTAINERS+=("$helper")
  docker run --rm --name "$helper" --label "$LABEL" --network none --user 0:0 \
    --volume "$WORK/bundle:/seed:ro" --volume "$RUN_ID-$region-tls:/tls" \
    "$POSTGRES_IMAGE" sh -ec \
    'cp /seed/server.crt /seed/server.key /tls/; chown postgres:postgres /tls/*; chmod 0600 /tls/server.key' >/dev/null
}
start_db() {
  local region=$1
  CONTAINERS+=("$RUN_ID-$region-db")
  docker run -d --name "$RUN_ID-$region-db" --label "$LABEL" \
    --network "$RUN_ID-$region-backend" --network-alias db \
    --env-file "$WORK/bundle/db.env" \
    --volume "$RUN_ID-$region-data:/var/lib/postgresql/data" \
    --volume "$RUN_ID-$region-tls:/tls:ro" \
    --security-opt no-new-privileges --memory 512m --cpus 1 \
    "$POSTGRES_IMAGE" -c ssl=on -c ssl_cert_file=/tls/server.crt -c ssl_key_file=/tls/server.key >/dev/null
  local i
  for i in $(seq 1 60); do
    if docker exec "$RUN_ID-$region-db" pg_isready -h 127.0.0.1 -U dx03v2 -d dx03v2 >/dev/null 2>&1; then return; fi
    sleep 1
  done
  die "database $region did not become ready"
}
start_app() {
  local region=$1 migration="$RUN_ID-$1-migrate"
  CONTAINERS+=("$migration" "$RUN_ID-$region-api" "$RUN_ID-$region-web")
  docker run --rm --name "$migration" --label "$LABEL" \
    --network "$RUN_ID-$region-backend" --env-file "$WORK/bundle/api.env" \
    --volume "$WORK/bundle/ca.crt:/tls/ca.crt:ro" \
    --read-only --cap-drop ALL --security-opt no-new-privileges \
    "$API_ID" dist/migrate.js
  docker run -d --name "$RUN_ID-$region-api" --label "$LABEL" \
    --network "$RUN_ID-$region-backend" --network-alias api \
    --env-file "$WORK/bundle/api.env" --volume "$WORK/bundle/ca.crt:/tls/ca.crt:ro" \
    --read-only --cap-drop ALL --security-opt no-new-privileges --memory 256m --cpus 1 \
    "$API_ID" >/dev/null
  docker network connect --alias api "$RUN_ID-$region-frontend" "$RUN_ID-$region-api"
  docker run -d --name "$RUN_ID-$region-web" --label "$LABEL" \
    --network "$RUN_ID-$region-frontend" -p 127.0.0.1::8080 \
    --read-only --tmpfs /tmp --cap-drop ALL --security-opt no-new-privileges \
    --memory 128m --cpus 0.5 "$WEB_ID" >/dev/null
  ENDPOINT[$region]="http://$(docker port "$RUN_ID-$region-web" 8080/tcp)"
  wait_app "$region"
  curl -fsS --max-time 5 "${ENDPOINT[$region]}/" | grep -q '<div id="root"' ||
    die "React artifact is absent in environment $region"
}
wait_app() {
  local region=$1 i
  for i in $(seq 1 60); do
    if curl -fsS --max-time 3 "${ENDPOINT[$region]}/api/messages" >"$WORK/messages.json"; then return; fi
    sleep 1
  done
  die "application $region did not recover"
}
write_marker() {
  curl -fsS --max-time 10 -H 'Content-Type: application/json' \
    --data "$(jq -nc --arg text "$2" '{author:"continuity",text:$text}')" \
    "${ENDPOINT[$1]}/api/messages" | jq -er '.id'
}
has_marker() {
  curl -fsS --max-time 5 "${ENDPOINT[$1]}/api/messages?limit=100" |
    jq -e --arg text "$2" '.items | any(.text == $text)' >/dev/null
}
backup() {
  docker exec "$RUN_ID-$1-db" pg_dump -U dx03v2 -d dx03v2 -Fc >"$2"
  [[ -s "$2" ]] || die 'empty database backup'
  docker exec -i "$RUN_ID-$1-db" pg_restore --list <"$2" >/dev/null
}
restore() {
  local region=$1 archive=$2 expected=$3
  [[ "$(sha256_of "$archive")" == "$expected" ]] || { log 'backup checksum mismatch'; return 1; }
  docker exec -i "$RUN_ID-$region-db" pg_restore -U dx03v2 -d dx03v2 --exit-on-error <"$archive"
}
# Refuse promotion whenever a writer in the previous environment is still running. A disconnected
# HTTP route alone is insufficient: both the API and database have to be physically fenced.
assert_fenced() {
  local region=$1 service state
  for service in api db web; do
    state="$(docker container inspect "$RUN_ID-$region-$service" --format '{{.State.Running}}')" || return 1
    [[ "$state" == false ]] || { log "refusing promotion: $region/$service is still running"; return 1; }
  done
}
fence() {
  docker stop "$RUN_ID-$1-web" "$RUN_ID-$1-api" "$RUN_ID-$1-db" >/dev/null
  assert_fenced "$1"
}

new_region a
new_region b
start_db a
start_app a
write_marker a committed-before-backup >/dev/null
# Database outage/reconnect with the exact same API process and container.
API_CONTAINER="$(docker inspect "$RUN_ID-a-api" --format '{{.Id}}')"
docker stop "$RUN_ID-a-db" >/dev/null
if curl -fsS --max-time 10 "${ENDPOINT[a]}/api/messages" >/dev/null 2>&1; then die 'API served data with the database stopped'; fi
docker start "$RUN_ID-a-db" >/dev/null
wait_app a
[[ "$(docker inspect "$RUN_ID-a-api" --format '{{.Id}}')" == "$API_CONTAINER" ]] || die 'reconnect restarted the API'
has_marker a committed-before-backup || die 'marker lost after database restart'

BACKUP_AT="$(date +%s)"
backup a "$WORK/a.dump"
BACKUP_SHA="$(sha256_of "$WORK/a.dump")"
write_marker a committed-after-backup >/dev/null
# Exercise the promotion safety gate before the failure; do not rely on a human remembering it.
if assert_fenced a; then die 'promotion accepted a live primary'; fi
cp "$WORK/a.dump" "$WORK/corrupt.dump"
printf 'corrupted' >>"$WORK/corrupt.dump"
start_db b
if restore b "$WORK/corrupt.dump" "$BACKUP_SHA"; then die 'corrupt backup was accepted'; fi
FAILURE_AT="$(date +%s)"
fence a
# Destroy the original application data. B must recover from the verified archive, never A's disk.
remove_owned volume "$RUN_ID-a-data" 2>"$WORK/in-use-volume.log" &&
  die 'Docker allowed removing an in-use primary data volume'
remove_owned container "$RUN_ID-a-web"
remove_owned container "$RUN_ID-a-api"
remove_owned container "$RUN_ID-a-db"
remove_owned volume "$RUN_ID-a-data"
restore b "$WORK/a.dump" "$BACKUP_SHA"
start_app b
has_marker b committed-before-backup || die 'acknowledged backup marker missing in B'
if has_marker b committed-after-backup; then die 'RPO fixture unexpectedly included a post-backup write'; fi
write_marker b committed-in-secondary >/dev/null
RECOVERY_AT="$(date +%s)"
RPO=$((FAILURE_AT - BACKUP_AT))
RTO=$((RECOVERY_AT - FAILURE_AT))
((RPO <= 120 && RTO <= 180)) || die "DR objective exceeded: RPO=$RPO RTO=$RTO seconds"

# Failback uses a NEW A disk and a fresh consistent backup from B, with B fenced before A serves.
backup b "$WORK/b.dump"
FAILBACK_SHA="$(sha256_of "$WORK/b.dump")"
if assert_fenced b; then die 'failback accepted a live secondary writer'; fi
FAILBACK_AT="$(date +%s)"
fence b
new_volume "$RUN_ID-a-data"
start_db a
restore a "$WORK/b.dump" "$FAILBACK_SHA"
start_app a
has_marker a committed-before-backup || die 'original marker absent after failback'
has_marker a committed-in-secondary || die 'secondary writes lost during failback'
write_marker a committed-after-failback >/dev/null
FAILBACK_RTO=$(($(date +%s) - FAILBACK_AT))
((FAILBACK_RTO <= 180)) || die 'failback exceeded 180 seconds'
assert_fenced b || die 'old secondary can write after failback'

jq -n --arg api "$API_ID" --arg web "$WEB_ID" --arg backup "$BACKUP_SHA" \
  --arg bundle "$BUNDLE_SHA" --argjson rpo "$RPO" --argjson rto "$RTO" \
  --argjson failback "$FAILBACK_RTO" \
  '{schema_version:1, environment:"isolated-docker", db_tls:"verify-full",
    images:{api:$api,web:$web},backup_sha256:$backup,configuration_bundle_sha256:$bundle,
    rpo_seconds:$rpo,rto_seconds:$rto,failback_seconds:$failback,
    intentionally_lost_post_backup_writes:1,
    checks:{reconnect_without_api_restart:true,live_primary_promotion_rejected:true,
      corrupt_backup_rejected:true,primary_disk_destroyed:true,
      restored_before_backup_write:true,secondary_write_survived_failback:true,
      old_writer_fenced:true}}' >"$REPORT_DIR/continuity.json"
cat "$REPORT_DIR/continuity.json"
echo 'PASS: independent A/B application recovery and fenced failback (Docker, no cloud homologation)'
