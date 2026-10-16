#!/usr/bin/env bash
# Publish a cloud deployment revision to the public GitOps branch. Only the source SHA, approved
# image digests, and committed example parameters enter Git; live values use the Argo CD Application.
set -euo pipefail

usage() {
  echo "usage: $0 <gcp> <gcp|gcp-waf> <source-commit-sha> <api-sha256-digest> <web-sha256-digest>" >&2
  exit 2
}

(($# == 5)) || usage
cloud=$1
overlay=$2
revision=$3
api_digest=$4
web_digest=$5
[[ "$cloud" == gcp ]] || usage
[[ "$revision" =~ ^[0-9a-f]{40}$ ]] || usage
[[ "$api_digest" =~ ^sha256:[0-9a-f]{64}$ && "$web_digest" =~ ^sha256:[0-9a-f]{64}$ ]] || usage
case "$cloud:$overlay" in
  gcp:gcp|gcp:gcp-waf) ;;
  *) usage ;;
esac

: "${REPO_ROOT:?source scripts/lib/common.sh before calling this script}"
branch="gitops/$cloud"
component="$REPO_ROOT/deploy/k8s/components/$cloud"
overlay_dir="deploy/k8s/overlays/$overlay"
app_name="$(basename "$REPO_ROOT")"
example_params="$component/params.example.env"
[[ -f "$example_params" && -f "$REPO_ROOT/$overlay_dir/kustomization.yaml" ]] || {
  echo "missing the example params or Kustomize overlay for $cloud/$overlay" >&2
  exit 1
}

tmp="$(mktemp -d)"
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT
remote="$(git -C "$REPO_ROOT" remote get-url origin)"
git clone --quiet --shared --no-checkout "$REPO_ROOT" "$tmp/repo"
git -C "$tmp/repo" remote set-url origin "$remote"
git -C "$tmp/repo" config user.name "${app_name} GitOps deploy"
git -C "$tmp/repo" config user.email "41898282+github-actions[bot]@users.noreply.github.com"
if [[ -n "${GITHUB_TOKEN:-}" ]]; then
  auth="$(printf 'x-access-token:%s' "$GITHUB_TOKEN" | base64 | tr -d '\r\n')"
  export GIT_CONFIG_COUNT=1
  export GIT_CONFIG_KEY_0=http.extraheader
  export GIT_CONFIG_VALUE_0="AUTHORIZATION: basic $auth"
fi

if ! remote_branch="$(git -C "$tmp/repo" ls-remote --heads origin "$branch")"; then
  echo "cannot read origin/$branch" >&2
  exit 1
fi
if [[ -n "$remote_branch" ]]; then
  git -C "$tmp/repo" fetch --quiet origin "$branch"
  git -C "$tmp/repo" checkout --quiet -B "$branch" FETCH_HEAD
  git -C "$tmp/repo" merge --no-edit "$revision" >/dev/null
else
  git -C "$tmp/repo" checkout --quiet -B "$branch" "$revision"
fi

cp "$tmp/repo/deploy/k8s/components/$cloud/params.example.env" \
  "$tmp/repo/deploy/k8s/components/$cloud/params.env"
cat >"$tmp/repo/$overlay_dir/gitops-revision.yaml" <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: gitops-revision
  labels:
    app.kubernetes.io/name: "$app_name"
    app.kubernetes.io/part-of: "$app_name"
data:
  source-commit: "$revision"
  api-image-tag: "$revision"
  web-image-tag: "$revision"
  api-image-digest: "$api_digest"
  web-image-digest: "$web_digest"
EOF

git -C "$tmp/repo" add -f "$overlay_dir/gitops-revision.yaml" \
  "deploy/k8s/components/$cloud/params.env"
if ! git -C "$tmp/repo" diff --cached --quiet; then
  git -C "$tmp/repo" commit --quiet -m "deploy: publish $app_name image revision ${revision:0:12}"
fi
gitops_revision="$(git -C "$tmp/repo" rev-parse HEAD)"

git -C "$tmp/repo" push --quiet origin "HEAD:refs/heads/$branch"
printf '%s\n' "$gitops_revision"
