#!/usr/bin/env bash
# Applies the repository settings of the v2 standard with idempotent `gh api` calls (run by the
# maintainer, never by CI). Needs gh authenticated as a repository admin.
# Usage: scripts/repo-guardrails.sh <owner/repo>
#   always:       vulnerability alerts, Dependabot security updates, delete_branch_on_merge,
#                 squash-only merges, read-only default GITHUB_TOKEN
#   public repo:  ruleset from .github/rulesets/main.json (required checks static, test, images,
#                 e2e), secret scanning + push protection, private vulnerability reporting,
#                 environment `lab` (owner as required reviewer, deployments from main only)
# Prints what was applied, what was skipped (e.g. private repo on the Free plan) and what failed.
# Exit 1 when any call failed.
set -euo pipefail

# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

RULESET_FILE="$REPO_ROOT/.github/rulesets/main.json"
declare -a APPLIED=() SKIPPED=() FAILED=()

step() { # DESCRIPTION CMD... -> runs CMD and records the outcome with the error message
  local what=$1 out
  shift
  if out="$("$@" 2>&1)"; then
    APPLIED+=("$what")
    log "ok    $what"
  else
    FAILED+=("$what: ${out//$'\n'/ }")
    log "FAIL  $what"
  fi
}

ruleset_upsert() {
  local repo=$1 name id
  name="$(awk -F'"' '/^  "name":/ { print $4; exit }' "$RULESET_FILE")"
  [[ -n "$name" ]] || die "cannot read the ruleset name from $RULESET_FILE"
  id="$(gh api "repos/$repo/rulesets" --jq ".[] | select(.name == \"$name\") | .id")"
  if [[ -n "$id" ]]; then
    gh api --method PUT "repos/$repo/rulesets/$id" --input "$RULESET_FILE" >/dev/null
  else
    gh api --method POST "repos/$repo/rulesets" --input "$RULESET_FILE" >/dev/null
  fi
}

secret_scanning() {
  gh api --method PATCH "repos/$1" --input - >/dev/null <<'JSON'
{
  "security_and_analysis": {
    "secret_scanning": { "status": "enabled" },
    "secret_scanning_push_protection": { "status": "enabled" }
  }
}
JSON
}

environment_lab() {
  local repo=$1 owner_id policies
  owner_id="$(gh api "users/${repo%%/*}" --jq '.id')"
  gh api --method PUT "repos/$repo/environments/lab" --input - >/dev/null <<JSON
{
  "wait_timer": 0,
  "prevent_self_review": false,
  "reviewers": [{ "type": "User", "id": $owner_id }],
  "deployment_branch_policy": { "protected_branches": false, "custom_branch_policies": true }
}
JSON
  policies="$(gh api "repos/$repo/environments/lab/deployment-branch-policies" --jq '.branch_policies[].name')"
  if ! grep -qx main <<<"$policies"; then
    gh api --method POST "repos/$repo/environments/lab/deployment-branch-policies" -f name=main -f type=branch >/dev/null
  fi
}

main() {
  if (($# != 1)) || [[ ! "$1" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
    echo "usage: $0 <owner/repo>" >&2
    exit 2
  fi
  local repo=$1 visibility
  require_cmd gh awk
  [[ -f "$RULESET_FILE" ]] || die "missing $RULESET_FILE"
  visibility="$(gh api "repos/$repo" --jq '.visibility')" || die "cannot read $repo (is gh authenticated as an admin?)"
  log "repository $repo ($visibility)"

  step "vulnerability alerts" gh api --method PUT "repos/$repo/vulnerability-alerts"
  step "Dependabot security updates" gh api --method PUT "repos/$repo/automated-security-fixes"
  step "squash-only merges + delete_branch_on_merge" gh api --method PATCH "repos/$repo" \
    -F allow_squash_merge=true -F allow_merge_commit=false -F allow_rebase_merge=false -F delete_branch_on_merge=true
  step "read-only GITHUB_TOKEN by default, Actions cannot approve PRs" gh api --method PUT "repos/$repo/actions/permissions/workflow" \
    -f default_workflow_permissions=read -F can_approve_pull_request_reviews=false

  if [[ "$visibility" == public ]]; then
    step "ruleset from .github/rulesets/main.json" ruleset_upsert "$repo"
    step "secret scanning + push protection" secret_scanning "$repo"
    step "private vulnerability reporting" gh api --method PUT "repos/$repo/private-vulnerability-reporting"
    step "environment lab (owner as required reviewer, main only)" environment_lab "$repo"
  else
    SKIPPED+=("ruleset, secret scanning + push protection, private vulnerability reporting and environment lab: the repository is $visibility (private repositories on the Free plan have no rulesets or environment reviewers); re-run after making it public (docs/PUBLICACAO.md)")
  fi

  echo
  echo "applied (${#APPLIED[@]}):"
  ((${#APPLIED[@]} == 0)) || printf '  - %s\n' "${APPLIED[@]}"
  echo "skipped (${#SKIPPED[@]}):"
  ((${#SKIPPED[@]} == 0)) || printf '  - %s\n' "${SKIPPED[@]}"
  echo "failed (${#FAILED[@]}):"
  if ((${#FAILED[@]} > 0)); then
    printf '  - %s\n' "${FAILED[@]}"
    exit 1
  fi
}

main "$@"
