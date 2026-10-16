#!/usr/bin/env bash
# OWASP ZAP Baseline against the disposable Compose app. No external host, credentials or cloud
# account is contacted. Reports stay outside the repository and Compose data is removed on exit.
set -euo pipefail

# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

PROJECT=dx03v2-r7-dast
ZAP_IMAGE='ghcr.io/zaproxy/zaproxy:2.17.0@sha256:5ccfff9a411743ab2615136a2edd7416bec9ce41572fa94e935df38c14adb2b6'
REPORT_DIR="${ZAP_REPORT_DIR:-${TMPDIR:-/tmp}/dx03v2-dast}"
WEB_PORT="${ZAP_TARGET_PORT:-18080}"
API_IMAGE="${DAST_API_IMAGE:-dx03v2-api:e2e}"
WEB_IMAGE="${DAST_WEB_IMAGE:-dx03v2-web:e2e}"
ENV_FILE=''

cleanup() {
  local rc=$?
  trap - EXIT
  if [[ -n "$ENV_FILE" ]]; then
    if ! docker compose -p "$PROJECT" --env-file "$ENV_FILE" down --volumes --remove-orphans; then
      log 'error: could not remove the disposable Compose services and volume'
      rc=1
    fi
    rm -f "$ENV_FILE"
  fi
  exit "$rc"
}
trap cleanup EXIT

require_cmd docker git openssl od tr
docker info >/dev/null 2>&1 || die 'Docker daemon is not reachable'
docker image inspect "$API_IMAGE" "$WEB_IMAGE" >/dev/null 2>&1 ||
  die "the prebuilt images $API_IMAGE and $WEB_IMAGE are required; run 'make build' first"
if [[ ! "$WEB_PORT" =~ ^[1-9][0-9]{0,4}$ ]] || ((10#$WEB_PORT > 65535)); then
  die "invalid ZAP_TARGET_PORT: $WEB_PORT"
fi
mkdir -p "$REPORT_DIR"
chmod 0777 "$REPORT_DIR"
cp security/dast-baseline.conf "$REPORT_DIR/zap-baseline.conf"
umask 077
ENV_FILE="$(mktemp "${TMPDIR:-/tmp}/dx03v2-dast-env.XXXXXX")"
{
  printf 'DB_NAME=dx03v2\n'
  printf 'DB_USER=dx03v2\n'
  printf 'DB_PASSWORD=%s\n' "$(rand_hex 24)"
  printf 'ADMIN_TOKEN=%s\n' "$(rand_hex 24)"
  printf 'API_IMAGE=%s\n' "$API_IMAGE"
  printf 'WEB_IMAGE=%s\n' "$WEB_IMAGE"
  printf 'WEB_PORT=%s\n' "$WEB_PORT"
  printf 'RATE_LIMIT_WRITE_PER_MINUTE=10\n'
  printf 'GIT_SHA=%s\n' "$(git -C "$REPO_ROOT" rev-parse --verify HEAD)"
} >"$ENV_FILE"

docker compose -p "$PROJECT" --env-file "$ENV_FILE" up -d --wait --wait-timeout 180

# The ZAP container shares the Linux runner network namespace so it can reach the app's loopback-only
# port. It runs unprivileged and receives no application secrets.
docker run --rm --network host --shm-size=512m \
  --cap-drop ALL --security-opt no-new-privileges \
  --volume "$REPORT_DIR:/zap/wrk/:rw" \
  "$ZAP_IMAGE" zap-baseline.py \
  -t "http://127.0.0.1:$WEB_PORT" \
  -c /zap/wrk/zap-baseline.conf \
  -j \
  -I \
  -m 5 \
  -T 10 \
  -J zap.json \
  -r zap.html

echo 'PASS: OWASP ZAP Baseline found no alert that violates the configured security policy.'
