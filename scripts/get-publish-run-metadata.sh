#!/usr/bin/env bash
# Resolve a successful publish-images run to the immutable artifact name it produced.
set -euo pipefail

# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

for name in RELEASE_RUN_ID GITHUB_REPOSITORY GITHUB_OUTPUT GH_TOKEN; do
  [[ -n "${!name:-}" ]] || die "$name is required"
done
[[ "$RELEASE_RUN_ID" =~ ^[1-9][0-9]*$ ]] || die 'RELEASE_RUN_ID must be a positive numeric run id'
[[ "$GITHUB_REF" == refs/heads/main ]] || die 'deploy must be dispatched from main'
require_cmd gh jq

run_json="$(gh api "repos/$GITHUB_REPOSITORY/actions/runs/$RELEASE_RUN_ID")" ||
  die "cannot read publisher run $RELEASE_RUN_ID"
jq -e --arg repo "$GITHUB_REPOSITORY" \
  '.name == "publish-images" and .path == ".github/workflows/publish-images.yml" and
   .event == "workflow_dispatch" and .head_branch == "main" and
   .head_repository.full_name == $repo and .status == "completed" and .conclusion == "success" and
   (.run_attempt | type == "number")' <<<"$run_json" >/dev/null ||
  die "run $RELEASE_RUN_ID is not a successful main-branch publish-images run"

source_sha="$(jq -er '.head_sha' <<<"$run_json")"
attempt="$(jq -er '.run_attempt' <<<"$run_json")"
artifact_name="dx03v2-release-${source_sha}-$RELEASE_RUN_ID-$attempt"
artifacts="$(gh api "repos/$GITHUB_REPOSITORY/actions/runs/$RELEASE_RUN_ID/artifacts?per_page=100")" ||
  die "cannot read artifacts for publisher run $RELEASE_RUN_ID"
jq -e --arg name "$artifact_name" \
  '[.artifacts[] | select(.name == $name and .expired == false and .size_in_bytes > 0)] | length == 1' \
  <<<"$artifacts" >/dev/null || die "publisher run has no usable release artifact $artifact_name"

{
  printf 'run_id=%s\n' "$RELEASE_RUN_ID"
  printf 'source_sha=%s\n' "$source_sha"
  printf 'publisher_attempt=%s\n' "$attempt"
  printf 'artifact_name=%s\n' "$artifact_name"
} >>"$GITHUB_OUTPUT"
log "publisher run $RELEASE_RUN_ID is successful; resolved artifact $artifact_name."
