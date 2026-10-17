#!/usr/bin/env bash
# Writes the in-toto predicate for each verified image promoted to Artifact Registry. The deploy workflow
# signs these statements only after verifying the source release and the destination digest.
set -euo pipefail

die() { echo "error: $*" >&2; exit 1; }

: "${RELEASE_DIR:?RELEASE_DIR is required}"
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
: "${GITHUB_RUN_ID:?GITHUB_RUN_ID is required}"
: "${RELEASE_RUN_ID:?RELEASE_RUN_ID is required}"
: "${API_AR_NAME:?API_AR_NAME is required}"
: "${API_AR_DIGEST:?API_AR_DIGEST is required}"
: "${WEB_AR_NAME:?WEB_AR_NAME is required}"
: "${WEB_AR_DIGEST:?WEB_AR_DIGEST is required}"

manifest="$RELEASE_DIR/release-manifest.json"
[[ -s "$manifest" ]] || die "verified release manifest is missing"
[[ "$API_AR_DIGEST" =~ ^sha256:[0-9a-f]{64}$ && "$WEB_AR_DIGEST" =~ ^sha256:[0-9a-f]{64}$ ]] ||
  die "Artifact Registry returned an invalid image digest"

source_sha="$(jq -er '.source.sha | select(test("^[0-9a-f]{40}$"))' "$manifest")" ||
  die "release source SHA is missing or invalid"
source_ci_run="$(jq -er '.source.ci_run_id | select(test("^[0-9]+$"))' "$manifest")" ||
  die "release CI run id is missing or invalid"
mkdir -p "$RUNNER_TEMP/dx03v2-promotion"

write_one() { # COMPONENT TARGET_NAME TARGET_DIGEST
  local component=$1 target_name=$2 target_digest=$3 source_name source_digest
  source_name="$(jq -er ".images.$component.name" "$manifest")"
  source_digest="$(jq -er --arg component "$component" '.images[$component].digest | select(test("^sha256:[0-9a-f]{64}$"))' "$manifest")" ||
    die "$component source digest is missing or invalid"
  jq -n \
    --arg repository "$GITHUB_REPOSITORY" \
    --arg source_sha "$source_sha" \
    --arg source_ci_run "$source_ci_run" \
    --arg source_name "$source_name" \
    --arg source_digest "$source_digest" \
    --arg target_name "$target_name" \
    --arg target_digest "$target_digest" \
    --arg workflow '.github/workflows/deploy-gcp.yml' \
    --arg promotion_run "$GITHUB_RUN_ID" \
    --arg release_run "$RELEASE_RUN_ID" \
    '{source: {repository: $repository, sha: $source_sha, ci_run_id: $source_ci_run,
              image: {name: $source_name, digest: $source_digest}},
      promotion: {workflow: $workflow, run_id: $promotion_run, release_run_id: $release_run,
                  target: {name: $target_name, digest: $target_digest}}}' \
    >"$RUNNER_TEMP/dx03v2-promotion/$component.json"
}

write_one api "$API_AR_NAME" "$API_AR_DIGEST"
write_one web "$WEB_AR_NAME" "$WEB_AR_DIGEST"
echo "Wrote promotion predicates for the two verified Artifact Registry digests."
