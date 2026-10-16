#!/usr/bin/env bash
# Manage the isolated SonarQube Community Build + PostgreSQL pair used by the CI test job.
set -euo pipefail

SONAR_NETWORK=dx03v2-sonar-ci
SONAR_DB_CONTAINER=dx03v2-sonar-db
SONAR_CONTAINER=dx03v2-sonarqube
SONAR_DB_IMAGE='postgres:17-alpine@sha256:b0f9560a2de083e2cc7382e75f808c7381a32852a7ec49117deedb300e552b24'
SONAR_IMAGE='sonarqube:26.10.0.133078-community@sha256:2e378f7852b67d43507d3d383ee8fb5a522b8b0f920be9803f74f72952fce8f1'

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    printf 'error: %s is required\n' "$1" >&2
    exit 1
  }
}

stop() {
  local container
  for container in "$SONAR_CONTAINER" "$SONAR_DB_CONTAINER"; do
    if docker container inspect "$container" >/dev/null 2>&1; then
      docker rm -f "$container" >/dev/null
    fi
  done
  if docker network inspect "$SONAR_NETWORK" >/dev/null 2>&1; then
    docker network rm "$SONAR_NETWORK" >/dev/null
  fi
}

start() {
  local health attempt
  sudo -n sysctl -w vm.max_map_count=524288
  docker network create "$SONAR_NETWORK" >/dev/null
  docker run --detach --name "$SONAR_DB_CONTAINER" \
    --network "$SONAR_NETWORK" --network-alias sonar-db \
    --health-cmd 'pg_isready -h 127.0.0.1 -U sonar -d sonar' \
    --health-interval 2s --health-timeout 3s --health-retries 30 \
    --env POSTGRES_DB=sonar --env POSTGRES_USER=sonar --env POSTGRES_PASSWORD=sonar \
    "$SONAR_DB_IMAGE" >/dev/null

  health=''
  for ((attempt = 1; attempt <= 60; attempt += 1)); do
    health="$(docker inspect --format '{{.State.Health.Status}}' "$SONAR_DB_CONTAINER")"
    [[ "$health" == healthy ]] && break
    [[ "$health" != unhealthy ]] || { echo 'error: Sonar PostgreSQL became unhealthy' >&2; exit 1; }
    sleep 2
  done
  [[ "$health" == healthy ]] || { echo 'error: Sonar PostgreSQL did not become healthy in 120 seconds' >&2; exit 1; }

  docker run --detach --name "$SONAR_CONTAINER" \
    --network "$SONAR_NETWORK" \
    --memory=4g \
    --ulimit nofile=131072:131072 \
    --ulimit nproc=8192:8192 \
    --publish 127.0.0.1:9000:9000 \
    --env SONAR_JDBC_URL=jdbc:postgresql://sonar-db:5432/sonar \
    --env SONAR_JDBC_USERNAME=sonar \
    --env SONAR_JDBC_PASSWORD=sonar \
    "$SONAR_IMAGE" >/dev/null
  echo 'Started the disposable SonarQube + PostgreSQL services.'
}

require_cmd docker
case "${1:-}" in
  start)
    require_cmd sudo
    start
    ;;
  stop)
    stop
    ;;
  *)
    echo "usage: $0 <start|stop>" >&2
    exit 2
    ;;
esac
