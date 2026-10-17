#!/usr/bin/env bash
# Verify a published release bundle, its source CI run, and identity-locked image attestations.
set -euo pipefail

# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

for name in RELEASE_DIR RELEASE_RUN_ID GITHUB_REPOSITORY GH_TOKEN; do
  [[ -n "${!name:-}" ]] || die "$name is required"
done
[[ "$RELEASE_RUN_ID" =~ ^[1-9][0-9]*$ ]] || die 'RELEASE_RUN_ID must be a positive numeric run id'
require_cmd gh jq sha256sum

manifest="$RELEASE_DIR/release-manifest.json"
[[ -f "$manifest" && ! -L "$manifest" ]] || die 'release-manifest.json is missing or is a symlink'
[[ -f "$RELEASE_DIR/api.spdx.json" && ! -L "$RELEASE_DIR/api.spdx.json" ]] || die 'API SBOM is missing or is a symlink'
[[ -f "$RELEASE_DIR/web.spdx.json" && ! -L "$RELEASE_DIR/web.spdx.json" ]] || die 'web SBOM is missing or is a symlink'

run_json="$(gh api "repos/$GITHUB_REPOSITORY/actions/runs/$RELEASE_RUN_ID")" ||
  die "cannot read publisher run $RELEASE_RUN_ID"
source_sha="$(jq -er '.source.sha' "$manifest")"
ci_run_id="$(jq -er '.source.ci_run_id' "$manifest")"
publisher_attempt="$(jq -er '.publisher.run_attempt' "$manifest")"
[[ "$source_sha" =~ ^[0-9a-f]{40}$ ]] || die 'release source SHA is invalid'
[[ "$ci_run_id" =~ ^[1-9][0-9]*$ ]] || die 'release source CI run id is invalid'
[[ "$publisher_attempt" =~ ^[1-9][0-9]*$ ]] || die 'publisher run attempt is invalid'

jq -e \
  --arg repo "$GITHUB_REPOSITORY" \
  --arg sha "$source_sha" \
  --arg run "$RELEASE_RUN_ID" \
  --arg attempt "$publisher_attempt" \
  '.schema_version == 1 and .repository == $repo and
   .source.ref == "refs/heads/main" and .source.sha == $sha and
   .publisher.workflow == ".github/workflows/publish-images.yml" and
   .publisher.run_id == $run and (.publisher.run_attempt | tostring) == $attempt and
   .publisher.release_tag == ("sha-" + $sha + "-ci-" + (.source.ci_run_id | tostring) +
     "-pub-" + $run + "-attempt-" + $attempt) and
   (.images.api.name | type == "string") and (.images.web.name | type == "string") and
   (.images.api.digest | test("^sha256:[0-9a-f]{64}$")) and
   (.images.web.digest | test("^sha256:[0-9a-f]{64}$")) and
   (.images.api.image_id | test("^sha256:[0-9a-f]{64}$")) and
   (.images.web.image_id | test("^sha256:[0-9a-f]{64}$")) and
   (.images.api.sbom_sha256 | test("^[0-9a-f]{64}$")) and
   (.images.web.sbom_sha256 | test("^[0-9a-f]{64}$"))' \
  "$manifest" >/dev/null || die 'release manifest has an invalid schema or identity'

[[ "$(jq -er '.repository' "$manifest")" == "$GITHUB_REPOSITORY" ]] || die 'release repository mismatch'
jq -e \
  --arg repo "$GITHUB_REPOSITORY" \
  --arg sha "$source_sha" \
  --arg attempt "$publisher_attempt" \
  '.name == "publish-images" and .path == ".github/workflows/publish-images.yml" and
   .event == "workflow_dispatch" and .head_branch == "main" and
   .head_repository.full_name == $repo and .status == "completed" and .conclusion == "success" and
   .head_sha == $sha and (.run_attempt | tostring) == $attempt' \
  <<<"$run_json" >/dev/null || die 'release publisher run does not match the manifest'

repo_lc="$(printf '%s' "$GITHUB_REPOSITORY" | tr '[:upper:]' '[:lower:]')"
for component in api web; do
  expected_name="ghcr.io/${repo_lc}/dx03v2-$component"
  actual_name="$(jq -er ".images.$component.name" "$manifest")"
  [[ "$actual_name" == "$expected_name" ]] || die "$component image is outside the expected GHCR namespace"
  expected_sbom="$(jq -er ".images.$component.sbom_sha256" "$manifest")"
  actual_sbom="$(sha256sum "$RELEASE_DIR/$component.spdx.json" | awk '{print $1}')"
  [[ "$actual_sbom" == "$expected_sbom" ]] || die "$component SBOM checksum does not match the release manifest"
done

ci_json="$(gh api "repos/$GITHUB_REPOSITORY/actions/runs/$ci_run_id")" ||
  die "cannot read source CI run $ci_run_id"
jq -e --arg repo "$GITHUB_REPOSITORY" --arg sha "$source_sha" \
  '.name == "ci" and .path == ".github/workflows/ci.yml" and .event == "push" and
   .head_branch == "main" and .head_repository.full_name == $repo and
   .head_sha == $sha and .status == "completed" and .conclusion == "success"' \
  <<<"$ci_json" >/dev/null || die 'source CI run is not a successful main push for this release SHA'
ci_attempt="$(jq -er '.run_attempt' <<<"$ci_json")"
jobs_json="$(gh api "repos/$GITHUB_REPOSITORY/actions/runs/$ci_run_id/jobs?per_page=100")" ||
  die 'cannot read required source CI jobs'
for required in static test images e2e e2e-platform continuity; do
  jq -e --arg name "$required" --argjson attempt "$ci_attempt" \
    '[.jobs[] | select(.name == $name and .run_attempt == $attempt and
      .status == "completed" and .conclusion == "success")] | length == 1' \
    <<<"$jobs_json" >/dev/null || die "source CI did not pass required job $required"
done

expected_workflow="$GITHUB_REPOSITORY/.github/workflows/publish-images.yml"
for component in api web; do
  name="$(jq -er ".images.$component.name" "$manifest")"
  digest="$(jq -er ".images.$component.digest" "$manifest")"
  image="oci://${name}@$digest"
  gh attestation verify "$image" --repo "$GITHUB_REPOSITORY" \
    --signer-workflow "$expected_workflow" \
    --cert-oidc-issuer https://token.actions.githubusercontent.com \
    --source-ref refs/heads/main --source-digest "$source_sha" --deny-self-hosted-runners >/dev/null ||
    die "$component image provenance is unsigned or has an unexpected identity"
  gh attestation verify "$image" --repo "$GITHUB_REPOSITORY" \
    --predicate-type https://spdx.dev/Document/v2.3 \
    --signer-workflow "$expected_workflow" \
    --cert-oidc-issuer https://token.actions.githubusercontent.com \
    --source-ref refs/heads/main --source-digest "$source_sha" --deny-self-hosted-runners >/dev/null ||
    die "$component image has no identity-locked SPDX attestation"
done

{
  printf 'source_sha=%s\n' "$source_sha"
  printf 'release_tag=%s\n' "$(jq -er '.publisher.release_tag' "$manifest")"
} >>"${GITHUB_OUTPUT:-/dev/null}"
log "release $source_sha passed source CI, SBOM, provenance and signer identity checks."
