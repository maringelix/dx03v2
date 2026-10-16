#!/usr/bin/env bash
# Negative integration test: submit a new, deliberately uncovered fixture and prove the
# Community Build Quality Gate rejected that exact analysis for its overall coverage condition.
set -euo pipefail

require_env() {
  [[ -n "${!1:-}" ]] || {
    printf 'error: %s is required\n' "$1" >&2
    exit 1
  }
}

require_env SONAR_HOST_URL
require_env SONAR_ADMIN_TOKEN
require_env SONAR_FIXTURE_TOKEN
require_env SONAR_FIXTURE_PROJECT
require_env SONAR_FIXTURE_SOURCE
require_env SONAR_SCANNER
require_env RUNNER_TEMP

command -v curl >/dev/null 2>&1 || { echo 'error: curl is required' >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo 'error: jq is required' >&2; exit 1; }
command -v grep >/dev/null 2>&1 || { echo 'error: grep is required' >&2; exit 1; }
command -v sed >/dev/null 2>&1 || { echo 'error: sed is required' >&2; exit 1; }
command -v head >/dev/null 2>&1 || { echo 'error: head is required' >&2; exit 1; }
command -v sleep >/dev/null 2>&1 || { echo 'error: sleep is required' >&2; exit 1; }
command -v seq >/dev/null 2>&1 || { echo 'error: seq is required' >&2; exit 1; }

[[ -x "$SONAR_SCANNER" ]] || { echo 'error: installed SonarScanner CLI is not executable' >&2; exit 1; }
[[ -s "$SONAR_FIXTURE_SOURCE/fixture.lcov" ]] || { echo 'error: the uncovered fixture has no LCOV report' >&2; exit 1; }
"$SONAR_SCANNER" --version | grep -Fq '8.1.0.6389' || {
  echo 'error: the cached SonarScanner version does not match the pinned version' >&2
  exit 1
}

host="${SONAR_HOST_URL%/}"
metadata="$RUNNER_TEMP/sonar-fixture-report-task.txt"
scan_log="$RUNNER_TEMP/sonar-fixture-scan.log"
rm -f "$metadata" "$scan_log"

set +e
(
  cd "$SONAR_FIXTURE_SOURCE"
  SONAR_HOST_URL="$host" SONAR_TOKEN="$SONAR_FIXTURE_TOKEN" "$SONAR_SCANNER" \
    -Dsonar.projectKey="$SONAR_FIXTURE_PROJECT" \
    -Dsonar.projectName="$SONAR_FIXTURE_PROJECT" \
    -Dsonar.sources=. \
    -Dsonar.javascript.lcov.reportPaths=fixture.lcov \
    -Dsonar.qualitygate.wait=true \
    -Dsonar.qualitygate.timeout=300 \
    -Dsonar.scanner.metadataFilePath="$metadata"
) >"$scan_log" 2>&1
scan_status=$?
set -e

[[ -s "$metadata" ]] || {
  echo 'error: scanner failed before uploading an analysis; this does not prove a Quality Gate rejection' >&2
  cat "$scan_log" >&2
  exit 1
}

task_id="$(sed -n 's/^ceTaskId=//p' "$metadata" | head -n 1)"
[[ "$task_id" =~ ^[A-Za-z0-9_-]+$ ]] || {
  echo 'error: scanner metadata has no valid Compute Engine task id' >&2
  exit 1
}

# ceTaskId is a Compute Engine task, not an analysisId. Resolve the completed task first so the
# quality-gate lookup is bound to the exact analysis submitted by this scanner invocation.
task_json=''
task_status=''
analysis_id=''
for ((attempt = 1; attempt <= 60; attempt += 1)); do
  task_json="$(curl --connect-timeout 5 --max-time 20 -fsS \
    -H "Authorization: Bearer $SONAR_ADMIN_TOKEN" \
    --get --data-urlencode "id=$task_id" \
    "$host/api/ce/task")" || {
      sleep 5
      continue
    }
  task_status="$(jq -r '.task.status // empty' <<<"$task_json")"
  case "$task_status" in
    SUCCESS)
      analysis_id="$(jq -r '.task.analysisId // empty' <<<"$task_json")"
      break
      ;;
    FAILED | CANCELED)
      echo "error: fixture Compute Engine task ended with $task_status" >&2
      jq -c '.task.errorMessage // .task' <<<"$task_json" >&2
      cat "$scan_log" >&2
      exit 1
      ;;
  esac
  sleep 5
done
[[ "$analysis_id" =~ ^[A-Za-z0-9_-]+$ ]] || {
  echo "error: fixture Compute Engine task did not produce an analysis id (status '${task_status:-missing}')" >&2
  if [[ -n "$task_json" ]]; then jq -c '.task // .' <<<"$task_json" >&2; fi
  cat "$scan_log" >&2
  exit 1
}

# Query that specific analysis (never a stale project status).
status_json=''
gate_status=''
for ((attempt = 1; attempt <= 12; attempt += 1)); do
  status_json="$(curl --connect-timeout 5 --max-time 20 -fsS \
    -H "Authorization: Bearer $SONAR_ADMIN_TOKEN" \
    --get --data-urlencode "analysisId=$analysis_id" \
    "$host/api/qualitygates/project_status")" || {
      sleep 1
      continue
    }
  gate_status="$(jq -r '.projectStatus.status // empty' <<<"$status_json")"
  [[ -n "$gate_status" ]] && break
  sleep 1
done

[[ "${gate_status:-}" == ERROR ]] || {
  echo "error: expected Quality Gate ERROR for fixture analysis, got '${gate_status:-missing}'" >&2
  cat "$scan_log" >&2
  jq -c '.projectStatus.conditions' <<<"$status_json" >&2
  exit 1
}
jq -e '.projectStatus.conditions | any(.metricKey == "coverage" and .status == "ERROR")' \
  <<<"$status_json" >/dev/null || {
    echo 'error: fixture gate failed for a reason other than insufficient overall coverage' >&2
    jq -c '.projectStatus.conditions' <<<"$status_json" >&2
    exit 1
  }

((scan_status != 0)) || {
  echo 'error: SonarScanner returned success despite the fixture Quality Gate failure' >&2
  exit 1
}

echo 'PASS: SonarQube rejected the exact fixture analysis because overall coverage was below 80%.'
