#!/usr/bin/env bash
# Validate a successful main-branch CI run and load only its checksummed image artifact.
set -euo pipefail

# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

for name in CI_RUN_ID ARTIFACT_DIR GITHUB_REPOSITORY GITHUB_SHA GH_TOKEN; do
  [[ -n "${!name:-}" ]] || die "$name is required"
done
[[ "$CI_RUN_ID" =~ ^[1-9][0-9]*$ ]] || die 'CI_RUN_ID must be a positive numeric run id'
[[ "$GITHUB_SHA" =~ ^[0-9a-f]{40}$ ]] || die 'GITHUB_SHA must be a full commit SHA'

require_cmd gh jq docker
[[ "$GITHUB_REF" == refs/heads/main ]] || die 'image publication must run from main'

run_json="$(gh api "repos/$GITHUB_REPOSITORY/actions/runs/$CI_RUN_ID")" ||
  die "cannot read CI run $CI_RUN_ID"
jq -e \
  --arg repo "$GITHUB_REPOSITORY" \
  --arg sha "$GITHUB_SHA" \
  '.name == "ci" and .path == ".github/workflows/ci.yml" and .event == "push" and
   .head_branch == "main" and .head_repository.full_name == $repo and
   .head_sha == $sha and .conclusion == "success" and (.run_attempt | type == "number")' \
  <<<"$run_json" >/dev/null ||
  die "CI run $CI_RUN_ID is not a successful push of this exact main commit"

run_attempt="$(jq -er '.run_attempt' <<<"$run_json")"
jobs_json="$(gh api "repos/$GITHUB_REPOSITORY/actions/runs/$CI_RUN_ID/jobs?per_page=100")" ||
  die "cannot read required jobs from CI run $CI_RUN_ID"
for required in static test images e2e e2e-platform continuity; do
  jq -e --arg name "$required" --argjson attempt "$run_attempt" \
    '[.jobs[] | select(.name == $name and .run_attempt == $attempt and
      .status == "completed" and .conclusion == "success")] | length == 1' \
    <<<"$jobs_json" >/dev/null || die "CI run $CI_RUN_ID did not pass required job $required"
done

archive="$ARTIFACT_DIR/dx03v2-images.tar"
manifest="$ARTIFACT_DIR/dx03v2-image-manifest.json"
[[ -f "$archive" && ! -L "$archive" ]] || die 'the CI image archive is missing or is a symlink'
[[ -f "$manifest" && ! -L "$manifest" ]] || die 'the CI image manifest is missing or is a symlink'
jq -e \
  --arg sha "$GITHUB_SHA" \
  --arg run "$CI_RUN_ID" \
  --argjson attempt "$run_attempt" \
  '.schema_version == 1 and .source_sha == $sha and .ci_run_id == $run and
   .ci_run_attempt == $attempt and
   .images.api.tag == "dx03v2-api:e2e" and .images.web.tag == "dx03v2-web:e2e" and
   (.image_tar_sha256 | test("^[0-9a-f]{64}$")) and
   (.images.api.image_id | test("^sha256:[0-9a-f]{64}$")) and
   (.images.web.image_id | test("^sha256:[0-9a-f]{64}$"))' \
  "$manifest" >/dev/null || die 'the CI image manifest does not match this release request'

expected_tar_sha="$(jq -er '.image_tar_sha256' "$manifest")"
actual_tar_sha="$(sha256_of "$archive")"
[[ "$actual_tar_sha" == "$expected_tar_sha" ]] || die 'the CI image archive checksum does not match its manifest'

docker load --input "$archive" >/dev/null
for image in api web; do
  tag="$(jq -er ".images.$image.tag" "$manifest")"
  expected_id="$(jq -er ".images.$image.image_id" "$manifest")"
  actual_id="$(docker image inspect "$tag" --format '{{.Id}}')"
  [[ "$actual_id" == "$expected_id" ]] || die "loaded image $tag does not match the CI image manifest"
done

log "CI run $CI_RUN_ID attempt $run_attempt passed all required jobs; both tested images match the archive."
