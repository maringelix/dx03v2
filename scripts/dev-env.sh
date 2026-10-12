#!/usr/bin/env bash
# Writes .env for compose.yaml with random local secrets (database password, admin token), mode 600.
# .env is gitignored; .env.example lists the same keys with placeholders. Values are never printed.
# Usage: scripts/dev-env.sh [--force]   (an existing .env is kept unless --force)
#   WEB_PORT (default 8080) and RATE_LIMIT_WRITE_PER_MINUTE (default 10) are read from the
#   environment when the file is written.
set -euo pipefail

# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

ENV_FILE="$REPO_ROOT/.env"

usage() {
  echo "usage: $0 [--force]" >&2
  exit 2
}

main() {
  local force=0 web_port=${WEB_PORT:-8080} rate=${RATE_LIMIT_WRITE_PER_MINUTE:-10} tmp
  case "$#:${1:-}" in
    0:) ;;
    1:--force) force=1 ;;
    *) usage ;;
  esac
  if [[ ! "$web_port" =~ ^[1-9][0-9]{0,4}$ ]] || ((web_port > 65535)); then
    die "WEB_PORT must be a TCP port (got '$web_port')"
  fi
  [[ "$rate" =~ ^[1-9][0-9]{0,3}$ ]] || die "RATE_LIMIT_WRITE_PER_MINUTE must be an integer from 1 to 9999 (got '$rate')"
  if [[ -f "$ENV_FILE" ]] && ((force == 0)); then
    log ".env already exists and was kept (scripts/dev-env.sh --force writes new secrets;"
    log "then run docker compose -p dx03v2-dev down -v, because the database keeps the old password)."
    return 0
  fi
  umask 077
  tmp="$(mktemp "$REPO_ROOT/.env.XXXXXX")"
  {
    echo "# Written by scripts/dev-env.sh ($(date -u +%Y-%m-%dT%H:%M:%SZ)). Local secrets: never commit this file."
    echo "DB_NAME=dx03v2"
    echo "DB_USER=dx03v2"
    echo "DB_PASSWORD=$(rand_hex 24)"
    echo "ADMIN_TOKEN=$(rand_hex 24)"
    echo "WEB_PORT=$web_port"
    echo "RATE_LIMIT_WRITE_PER_MINUTE=$rate"
    echo "GIT_SHA=unknown"
  } >"$tmp"
  mv -f "$tmp" "$ENV_FILE"
  log "wrote .env (random DB_PASSWORD and ADMIN_TOKEN, web on 127.0.0.1:$web_port)."
  log "next: docker compose -p dx03v2-dev up -d --build --wait && scripts/compose-smoke.sh"
}

main "$@"
