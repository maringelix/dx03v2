#!/usr/bin/env bash
# Push the verified CI images to a unique GHCR tag without rebuilding them.
set -euo pipefail

# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

for name in ARTIFACT_DIR CI_RUN_ID GITHUB_REPOSITORY GITHUB_RUN_ID GITHUB_RUN_ATTEMPT GITHUB_OUTPUT; do
  [[ -n "${!name:-}" ]] || die "$name is required"
done

manifest="$ARTIFACT_DIR/dx03v2-image-manifest.json"
[[ -s "$manifest" ]] || die 'the verified CI image manifest is missing'
source_sha="$(jq -er '.source_sha' "$manifest")"
[[ "$source_sha" =~ ^[0-9a-f]{40}$ ]] || die 'the image manifest has no valid source SHA'
repo_lc="$(printf '%s' "$GITHUB_REPOSITORY" | tr '[:upper:]' '[:lower:]')"
[[ "$repo_lc" =~ ^[a-z0-9._-]+/[a-z0-9._-]+$ ]] || die 'GITHUB_REPOSITORY is not a valid GHCR namespace'

release_tag="sha-${source_sha}-ci-${CI_RUN_ID}-pub-${GITHUB_RUN_ID}-attempt-${GITHUB_RUN_ATTEMPT}"
api_name="ghcr.io/$repo_lc/dx03v2-api"
web_name="ghcr.io/$repo_lc/dx03v2-web"

push_image() { # LOCAL_TAG REGISTRY_NAME EXPECTED_IMAGE_ID
  local local_tag=$1 name=$2 expected_id=$3 push_output push_status digest remote_id
  local ref="$name:$release_tag"
  docker tag "$local_tag" "$ref"
  if push_output="$(docker push "$ref" 2>&1)"; then
    printf '%s\n' "$push_output" >&2
  else
    push_status=$?
    printf '%s\n' "$push_output" >&2
    return "$push_status"
  fi
  digest="$(printf '%s\n' "$push_output" | grep -Eo 'digest: sha256:[0-9a-f]{64}' | tail -n 1 | cut -d ' ' -f 2)"
  [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || die "registry did not return a valid digest for $ref"
  docker pull "$name@$digest" >/dev/null
  remote_id="$(docker image inspect "$name@$digest" --format '{{.Id}}')"
  [[ "$remote_id" == "$expected_id" ]] || die "registry content for $name@$digest differs from the tested CI image"
  printf '%s\t%s\t%s\n' "$name" "$digest" "$remote_id"
}

api_result="$(push_image dx03v2-api:e2e "$api_name" "$(jq -er '.images.api.image_id' "$manifest")")"
web_result="$(push_image dx03v2-web:e2e "$web_name" "$(jq -er '.images.web.image_id' "$manifest")")"
IFS=$'\t' read -r api_name api_digest api_image_id <<<"$api_result"
IFS=$'\t' read -r web_name web_digest web_image_id <<<"$web_result"

{
  printf 'release_tag=%s\n' "$release_tag"
  printf 'api_name=%s\n' "$api_name"
  printf 'api_digest=%s\n' "$api_digest"
  printf 'api_image_id=%s\n' "$api_image_id"
  printf 'web_name=%s\n' "$web_name"
  printf 'web_digest=%s\n' "$web_digest"
  printf 'web_image_id=%s\n' "$web_image_id"
} >>"$GITHUB_OUTPUT"

log "Published the CI-tested API and web images at unique tag $release_tag without rebuilding."
