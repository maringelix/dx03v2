#!/usr/bin/env bash
# Offline test of the signed Artifact Registry promotion predicate used by the Google Cloud deploy workflow.
set -euo pipefail

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/release" "$tmp/runner"

cat >"$tmp/release/release-manifest.json" <<'JSON'
{
  "source": {
    "sha": "1111111111111111111111111111111111111111",
    "ci_run_id": "12345"
  },
  "images": {
    "api": {
      "name": "ghcr.io/maringelix/dx03v2/api",
      "digest": "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    },
    "web": {
      "name": "ghcr.io/maringelix/dx03v2/web",
      "digest": "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    }
  }
}
JSON

RELEASE_DIR="$tmp/release" \
GITHUB_REPOSITORY=maringelix/dx03v2 \
GITHUB_RUN_ID=9001 \
RELEASE_RUN_ID=8123 \
RUNNER_TEMP="$tmp/runner" \
GITHUB_OUTPUT="$tmp/github-output" \
API_AR_NAME=us-central1-docker.pkg.dev/tx03v2-lab-example/dx03v2/api \
API_AR_DIGEST=sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc \
WEB_AR_NAME=us-central1-docker.pkg.dev/tx03v2-lab-example/dx03v2/web \
WEB_AR_DIGEST=sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd \
  bash scripts/write-promotion-statements.sh

jq -e \
  --arg repository maringelix/dx03v2 \
  --arg source_sha 1111111111111111111111111111111111111111 \
  --arg source_name ghcr.io/maringelix/dx03v2/api \
  --arg source_digest sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
  --arg target_name us-central1-docker.pkg.dev/tx03v2-lab-example/dx03v2/api \
  --arg target_digest sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc \
  --arg promotion_run 9001 \
  --arg release_run 8123 \
  '.source.repository == $repository and
   .source.sha == $source_sha and
   .source.ci_run_id == "12345" and
   .source.image.name == $source_name and
   .source.image.digest == $source_digest and
   .promotion.workflow == ".github/workflows/deploy-gcp.yml" and
   .promotion.run_id == $promotion_run and
   .promotion.release_run_id == $release_run and
   .promotion.target.name == $target_name and
   .promotion.target.digest == $target_digest' \
  "$tmp/runner/dx03v2-promotion/api.json" >/dev/null

jq -e \
  --arg target_name us-central1-docker.pkg.dev/tx03v2-lab-example/dx03v2/web \
  --arg target_digest sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd \
  '.promotion.target.name == $target_name and .promotion.target.digest == $target_digest' \
  "$tmp/runner/dx03v2-promotion/web.json" >/dev/null

if API_AR_DIGEST=sha256:invalid \
  RELEASE_DIR="$tmp/release" \
  GITHUB_REPOSITORY=maringelix/dx03v2 \
  GITHUB_RUN_ID=9001 \
  RELEASE_RUN_ID=8123 \
  RUNNER_TEMP="$tmp/invalid-digest" \
  GITHUB_OUTPUT="$tmp/invalid-digest-output" \
  API_AR_NAME=us-central1-docker.pkg.dev/tx03v2-lab-example/dx03v2/api \
  WEB_AR_DIGEST=sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd \
  WEB_AR_NAME=us-central1-docker.pkg.dev/tx03v2-lab-example/dx03v2/web \
  bash scripts/write-promotion-statements.sh >/dev/null 2>&1; then
  echo "promotion statement writer must reject an invalid Artifact Registry digest" >&2
  exit 1
fi

mkdir -p "$tmp/invalid-source"
jq '.source.sha = "not-a-commit"' "$tmp/release/release-manifest.json" >"$tmp/invalid-source/release-manifest.json"
if RELEASE_DIR="$tmp/invalid-source" \
  GITHUB_REPOSITORY=maringelix/dx03v2 \
  GITHUB_RUN_ID=9001 \
  RELEASE_RUN_ID=8123 \
  RUNNER_TEMP="$tmp/invalid-source-output" \
  GITHUB_OUTPUT="$tmp/invalid-source-github-output" \
  API_AR_NAME=us-central1-docker.pkg.dev/tx03v2-lab-example/dx03v2/api \
  API_AR_DIGEST=sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc \
  WEB_AR_NAME=us-central1-docker.pkg.dev/tx03v2-lab-example/dx03v2/web \
  WEB_AR_DIGEST=sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd \
  bash scripts/write-promotion-statements.sh >/dev/null 2>&1; then
  echo "promotion statement writer must reject a release without a valid source commit" >&2
  exit 1
fi

echo "promotion statements bind the verified source commit and both Artifact Registry digests; invalid input is rejected"
