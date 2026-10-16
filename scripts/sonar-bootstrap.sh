#!/usr/bin/env bash
# Starts from SonarQube's one-time admin credential, provisions isolated projects and issues
# project-scoped analysis tokens. Tokens are masked and passed only to later steps in this job.
set -euo pipefail

require_env() {
  [[ -n "${!1:-}" ]] || {
    printf 'error: %s is required\n' "$1" >&2
    exit 1
  }
}

require_env SONAR_HOST_URL
require_env SONAR_PROJECT_KEY
require_env SONAR_FIXTURE_PROJECT
require_env GITHUB_ENV

command -v curl >/dev/null 2>&1 || { echo 'error: curl is required' >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo 'error: jq is required' >&2; exit 1; }
command -v openssl >/dev/null 2>&1 || { echo 'error: openssl is required' >&2; exit 1; }

sonar_request() { # LABEL CURL_ARGS...
  local label="$1" response_file http_status curl_status response_body
  shift
  response_file="$(mktemp "${TMPDIR:-/tmp}/sonar-api.XXXXXX")"
  if http_status="$(curl --connect-timeout 5 --max-time 20 --silent --show-error \
    --output "$response_file" --write-out '%{http_code}' "$@")"; then
    :
  else
    curl_status=$?
    response_body="$(cat "$response_file")"
    rm -f "$response_file"
    printf 'error: Sonar API %s failed (curl exit %s): %s\n' "$label" "$curl_status" "${response_body:-no response body}" >&2
    return "$curl_status"
  fi
  if [[ ! "$http_status" =~ ^2[0-9]{2}$ ]]; then
    response_body="$(cat "$response_file")"
    rm -f "$response_file"
    printf 'error: Sonar API %s returned HTTP %s: %s\n' "$label" "$http_status" "${response_body:-no response body}" >&2
    return 1
  fi
  cat "$response_file"
  rm -f "$response_file"
}

extract_token() { # LABEL RESPONSE_JSON
  local label="$1" payload="$2" token response_summary
  if token="$(jq -er '.token | select(type == "string" and length >= 20)' <<<"$payload")"; then
    printf '%s' "$token"
    return 0
  fi
  response_summary="$(jq -c 'if type == "object" then {keys: keys, errors: (.errors // null)} else {type: type} end' \
    <<<"$payload" 2>/dev/null || echo 'invalid JSON response')"
  printf 'error: Sonar API %s did not return a token (%s)\n' "$label" "$response_summary" >&2
  return 1
}

host="${SONAR_HOST_URL%/}"
admin_password="Aa1!$(openssl rand -hex 32)"
ready=0

for ((attempt = 1; attempt <= 180; attempt += 1)); do
  if body="$(curl --connect-timeout 3 --max-time 5 -fsS "$host/api/system/status" 2>/dev/null)" \
    && [[ "$(jq -r '.status // empty' <<<"$body")" == UP ]]; then
    ready=1
    break
  fi
  sleep 5
done
((ready == 1)) || { echo 'error: SonarQube did not become ready within 15 minutes' >&2; exit 1; }
echo 'SonarQube is ready.'

# Community Build initializes with admin/admin. Rotate that credential immediately; the generated
# replacement is never written to the job environment or logs.
bootstrap_user='admin'
bootstrap_password='admin'
sonar_request 'rotate the default admin password' -u "$bootstrap_user:$bootstrap_password" -X POST \
  --data-urlencode 'login=admin' \
  --data-urlencode 'previousPassword=admin' \
  --data-urlencode "password=$admin_password" \
  "$host/api/users/change_password" >/dev/null
unset bootstrap_user bootstrap_password
echo 'Rotated the disposable SonarQube admin password.'

admin_payload="$(sonar_request 'generate the temporary admin token' -u "admin:$admin_password" -X POST \
  --data-urlencode 'name=ci-administration-bootstrap' \
  --data-urlencode 'type=USER_TOKEN' \
  "$host/api/user_tokens/generate")"
admin_token="$(extract_token 'generate the temporary admin token' "$admin_payload")"
unset admin_password admin_payload

printf '::add-mask::%s\n' "$admin_token"
echo 'Generated the disposable administration token.'

api_post() {
  local path="$1"
  shift
  sonar_request "$path" -H "Authorization: Bearer $admin_token" \
    -X POST "$@" "$host$path"
}

create_project() {
  local key="$1" name="$2" token_name="$3" token_payload project_token
  api_post /api/projects/create --data-urlencode "project=$key" --data-urlencode "name=$name" >/dev/null
  token_payload="$(api_post /api/user_tokens/generate \
    --data-urlencode "name=$token_name" \
    --data-urlencode 'type=PROJECT_ANALYSIS_TOKEN' \
    --data-urlencode "projectKey=$key")"
  project_token="$(extract_token "generate project analysis token for $key" "$token_payload")"
  unset token_payload
  printf 'Created disposable SonarQube project and analysis token for %s.\n' "$key" >&2
  printf '%s' "$project_token"
}

suffix="${GITHUB_RUN_ID:-local}-${GITHUB_RUN_ATTEMPT:-1}"
main_token="$(create_project "$SONAR_PROJECT_KEY" "$SONAR_PROJECT_KEY" "ci-$suffix-main")"
fixture_token="$(create_project "$SONAR_FIXTURE_PROJECT" "$SONAR_FIXTURE_PROJECT" "ci-$suffix-fixture")"
printf '::add-mask::%s\n' "$main_token"
printf '::add-mask::%s\n' "$fixture_token"
echo 'Created both disposable SonarQube projects.'

# The fixture is often analyzed for the first time, when Sonar has no new-code baseline. Give only
# that disposable project a gate that also requires overall coverage, so its zero-coverage LCOV
# proves a real gate failure on every run.
fixture_gate="ci-fixture-$suffix"
api_post /api/qualitygates/create --data-urlencode "name=$fixture_gate" >/dev/null
api_post /api/qualitygates/create_condition \
  --data-urlencode "gateName=$fixture_gate" \
  --data-urlencode 'metric=coverage' \
  --data-urlencode 'op=LT' \
  --data-urlencode 'error=80' >/dev/null
api_post /api/qualitygates/select \
  --data-urlencode "gateName=$fixture_gate" \
  --data-urlencode "projectKey=$SONAR_FIXTURE_PROJECT" >/dev/null
echo "Associated the disposable fixture project with quality gate $fixture_gate."

{
  printf 'SONAR_ADMIN_TOKEN=%s\n' "$admin_token"
  printf 'SONAR_TOKEN=%s\n' "$main_token"
  printf 'SONAR_FIXTURE_TOKEN=%s\n' "$fixture_token"
} >>"$GITHUB_ENV"

unset admin_token main_token fixture_token
echo 'SonarQube projects and project-scoped analysis tokens are ready.'
