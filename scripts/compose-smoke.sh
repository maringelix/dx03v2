#!/usr/bin/env bash
# Smoke test of the running compose stack (project dx03v2-dev) through the published web port, the
# same e2e/smoke.mjs used on kind and on Google Cloud:
#   scripts/dev-env.sh
#   docker compose -p dx03v2-dev up -d --build --wait
#   scripts/compose-smoke.sh
#   docker compose -p dx03v2-dev down -v
# Reads WEB_PORT and ADMIN_TOKEN from .env (the token is never printed). BASE_URL overrides the
# address (default http://127.0.0.1:<WEB_PORT>); SMOKE_WAIT_SECONDS defaults to 60.
set -euo pipefail

# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

PROJECT=dx03v2-dev
ENV_FILE="$REPO_ROOT/.env"

main() {
  local port token base services s
  (($# == 0)) || die "usage: $0 (no arguments; see the header)"
  require_cmd docker node
  [[ -f "$ENV_FILE" ]] || die ".env not found: run scripts/dev-env.sh first"
  port="$(env_file_value "$ENV_FILE" WEB_PORT)"
  port="${port:-8080}"
  token="$(env_file_value "$ENV_FILE" ADMIN_TOKEN)"
  [[ ${#token} -ge 32 ]] || die "ADMIN_TOKEN in .env must have at least 32 characters (run scripts/dev-env.sh --force)"
  services="$(docker compose -p "$PROJECT" ps --status running --services)"
  for s in db api web; do
    grep -qx "$s" <<<"$services" || die "service $s of project $PROJECT is not running (docker compose -p $PROJECT up -d --build --wait)"
  done
  base="${BASE_URL:-http://127.0.0.1:$port}"
  log "smoke test of project $PROJECT against $base"
  BASE_URL="$base" ADMIN_TOKEN="$token" SMOKE_WAIT_SECONDS="${SMOKE_WAIT_SECONDS:-60}" node "$REPO_ROOT/e2e/smoke.mjs"
}

main "$@"
