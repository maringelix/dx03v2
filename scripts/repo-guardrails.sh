#!/usr/bin/env bash
# Applies the repository settings of the v2 standard with idempotent `gh api` calls. GitHub copies no
# settings to a fork: run it once on every fork (FORK.md) and again after a change of the ruleset;
# never from CI. Needs gh authenticated as an administrator of the repository.
# Usage: scripts/repo-guardrails.sh <owner/repo>
#   always:       vulnerability alerts, Dependabot security updates, squash-only merges,
#                 delete_branch_on_merge, issues (the issue forms, e.g. cloud_run_report),
#                 read-only default GITHUB_TOKEN
#   public repo:  ruleset from .github/rulesets/main.json (with its required status checks), secret
#                 scanning + push protection, private vulnerability reporting, approval of workflow
#                 runs from forks of every external contributor
#   always:       environment `lab` (the gh user that runs this script as required reviewer,
#                 deployments from main only). The cloud workflows take their credentials through it,
#                 so a repository where it cannot be protected is a failure, not a skip
#   checks:       GitHub Actions enabled (a fork keeps its workflows disabled until you enable them);
#                 the OIDC subject of the repository is the immutable one the cloud trust expects
#                 (owner and repository IDs, which are printed for the bootstrap variables); the
#                 argument is the repository of this checkout; notes when the repository name or
#                 .github/CODEOWNERS do not fit the fork
# Prints what was applied, what was skipped, the notes and what failed. Exit 1 when anything failed.
set -euo pipefail

# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

RULESET_FILE="$REPO_ROOT/.github/rulesets/main.json"
CODEOWNERS_FILE="$REPO_ROOT/.github/CODEOWNERS"
declare -a APPLIED=() SKIPPED=() NOTES=() FAILED=()

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

fork_pr_approval() {
  gh api --method PUT "repos/$1/actions/permissions/fork-pr-contributor-approval" --input - >/dev/null <<'JSON'
{ "approval_policy": "all_external_contributors" }
JSON
}

environment_lab() { # REPO REVIEWER_ID
  local repo=$1 reviewer_id=$2 policies name id
  gh api --method PUT "repos/$repo/environments/lab" --input - >/dev/null <<JSON
{
  "wait_timer": 0,
  "prevent_self_review": false,
  "reviewers": [{ "type": "User", "id": $reviewer_id }],
  "deployment_branch_policy": { "protected_branches": false, "custom_branch_policies": true }
}
JSON
  policies="$(gh api "repos/$repo/environments/lab/deployment-branch-policies" --jq '.branch_policies[] | "\(.id) \(.name)"')"
  if ! grep -qE '^[0-9]+ main$' <<<"$policies"; then
    gh api --method POST "repos/$repo/environments/lab/deployment-branch-policies" -f name=main -f type=branch >/dev/null
  fi
  # main only: any other branch the environment already allowed is removed.
  while read -r id name; do
    [[ -n "$id" && "$name" != main ]] || continue
    gh api --method DELETE "repos/$repo/environments/lab/deployment-branch-policies/$id" >/dev/null
  done <<<"$policies"
  # Read it back: the environment must really hold a reviewer and only main.
  gh api "repos/$repo/environments/lab" --jq '[.protection_rules[]? | select(.type == "required_reviewers")] | length' |
    grep -qx '[1-9][0-9]*' || {
    echo "the environment lab has no required reviewer after the update"
    return 1
  }
  policies="$(gh api "repos/$repo/environments/lab/deployment-branch-policies" --jq '[.branch_policies[].name] | join(",")')"
  [[ "$policies" == main ]] || {
    echo "the environment lab allows deployments from '$policies', not only main"
    return 1
  }
}

# oidc_subject REPO -> records a failure when the OIDC subject of the repository is still the
# name-based one (the bootstrap trusts the immutable one: repo:<owner>@<owner id>/<repo>@<repo id>)
# and notes the numeric IDs the bootstrap variables need.
oidc_subject() {
  local repo=$1 prefix owner_id repo_id
  owner_id="$(gh api "repos/$repo" --jq '.owner.id' 2>/dev/null)" || owner_id=""
  repo_id="$(gh api "repos/$repo" --jq '.id' 2>/dev/null)" || repo_id=""
  if [[ -n "$owner_id" && -n "$repo_id" ]]; then
    NOTES+=("IDs for the bootstrap variables of $repo: owner $owner_id (github_owner_id), repository $repo_id (<repository>_repository_id)")
  fi
  if ! prefix="$(gh api "repos/$repo/actions/oidc/customization/sub" --jq '.sub_claim_prefix // empty' 2>/dev/null)"; then
    NOTES+=("cannot read the OIDC subject template of $repo (needs an administrator): check by hand that its subject has the owner and repository IDs, as docs/RUNBOOK.md explains")
    return 0
  fi
  if [[ -z "$prefix" ]]; then
    NOTES+=("the API did not return sub_claim_prefix for $repo: check by hand that the OIDC subject carries the owner and repository IDs")
    return 0
  fi
  if [[ "$prefix" =~ ^repo:[A-Za-z0-9_.-]+@[0-9]+/[A-Za-z0-9_.-]+@[0-9]+$ ]]; then
    log "ok    OIDC subject is the immutable one ($prefix)"
  else
    FAILED+=("the OIDC subject of $repo is name-based ($prefix) and the cloud trust expects the immutable one: opt in to immutable subject claims in Settings > Actions > General > OpenID Connect (docs/RUNBOOK.md, section 2), then run this script again")
  fi
}

# check_checkout REPO -> the argument must be the repository this checkout was cloned from: the
# script changes settings of a repository, so a typo or a copy of an old command must not reach
# another one.
check_checkout() {
  local repo=$1 origin
  origin="$(git -C "$REPO_ROOT" remote get-url origin 2>/dev/null)" || return 0
  origin="${origin%.git}"
  origin="${origin##*github.com[:/]}"
  if [[ "${origin,,}" != "${repo,,}" ]]; then
    die "this checkout comes from '$origin', not from '$repo': run the script from a clone of the repository you name"
  fi
}

# check_actions REPO -> records a failure when GitHub Actions cannot run: without them the required
# status checks never report and no pull request can be merged.
check_actions() {
  local repo=$1 enabled disabled
  if ! enabled="$(gh api "repos/$repo/actions/permissions" --jq '.enabled' 2>&1)"; then
    FAILED+=("cannot read the Actions permissions of $repo: ${enabled//$'\n'/ }")
    return 0
  fi
  if [[ "$enabled" != true ]]; then
    FAILED+=("GitHub Actions are disabled in Settings > Actions > General of $repo: allow them, then run this script again")
    return 0
  fi
  if ! disabled="$(gh api --paginate "repos/$repo/actions/workflows" --jq '.workflows[] | select(.state == "disabled_fork") | .path' 2>&1)"; then
    FAILED+=("cannot list the workflows of $repo: ${disabled//$'\n'/ }")
    return 0
  fi
  if [[ -n "$disabled" ]]; then
    FAILED+=("the workflows of this fork are not enabled yet ($(tr '\n' ' ' <<<"$disabled")): open the Actions tab of $repo, click 'I understand my workflows, go ahead and enable them', then run this script again")
    return 0
  fi
  log "ok    GitHub Actions enabled"
}

# fork_notes REPO -> what a fork still has to change by hand (FORK.md).
fork_notes() {
  local repo=$1 owner=${1%%/*} name=${1##*/} expected
  expected="$(awk 'NR == 1 { sub(/^# /, ""); print; exit }' "$REPO_ROOT/README.md")"
  if [[ -n "$expected" && "$name" != "$expected" ]]; then
    NOTES+=("the repository is named $name, not $expected: the cloud identities of the bootstrap trust the original names, keep them (FORK.md)")
  fi
  if [[ -f "$CODEOWNERS_FILE" ]] && ! grep -qiE "(^|[[:space:]])@$owner([[:space:]]|\$)" "$CODEOWNERS_FILE"; then
    NOTES+=(".github/CODEOWNERS does not name @$owner: replace the owner in a pull request of your fork (FORK.md)")
  fi
}

main() {
  if (($# != 1)) || [[ ! "$1" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
    echo "usage: $0 <owner/repo>" >&2
    exit 2
  fi
  local repo=$1 visibility reviewer reviewer_id checks
  require_cmd gh awk
  [[ -f "$RULESET_FILE" ]] || die "missing $RULESET_FILE"
  check_checkout "$repo"
  visibility="$(gh api "repos/$repo" --jq '.visibility')" || die "cannot read $repo (is gh authenticated as an admin?)"
  reviewer="$(gh api user --jq '.login')" || die "cannot read the authenticated gh user"
  reviewer_id="$(gh api user --jq '.id')" || die "cannot read the authenticated gh user"
  checks="$(awk -F'"' '/"context":/ { printf "%s%s", sep, $4; sep = ", " }' "$RULESET_FILE")"
  log "repository $repo ($visibility), as $reviewer"

  check_actions "$repo"
  step "vulnerability alerts" gh api --method PUT "repos/$repo/vulnerability-alerts"
  step "Dependabot security updates" gh api --method PUT "repos/$repo/automated-security-fixes"
  step "squash-only merges + delete_branch_on_merge" gh api --method PATCH "repos/$repo" \
    -F allow_squash_merge=true -F allow_merge_commit=false -F allow_rebase_merge=false -F delete_branch_on_merge=true
  step "issues (the issue forms, including cloud_run_report)" gh api --method PATCH "repos/$repo" -F has_issues=true
  step "read-only GITHUB_TOKEN by default, Actions cannot approve PRs" gh api --method PUT "repos/$repo/actions/permissions/workflow" \
    -f default_workflow_permissions=read -F can_approve_pull_request_reviews=false

  if [[ "$visibility" == public ]]; then
    step "ruleset from .github/rulesets/main.json (required checks: $checks)" ruleset_upsert "$repo"
    step "secret scanning + push protection" secret_scanning "$repo"
    step "private vulnerability reporting" gh api --method PUT "repos/$repo/private-vulnerability-reporting"
    step "approval of workflow runs from forks of every external contributor" fork_pr_approval "$repo"
  else
    SKIPPED+=("ruleset, secret scanning + push protection, private vulnerability reporting and fork run approval: the repository is $visibility (private repositories on the Free plan have none of them); re-run after making it public (docs/PUBLISHING.md)")
  fi
  # The environment is what the cloud workflows authenticate through: it is never skipped. A private
  # repository without environment reviewers (Free plan) fails here, on purpose.
  step "environment lab (reviewer @$reviewer, main only)" environment_lab "$repo" "$reviewer_id"
  oidc_subject "$repo"
  fork_notes "$repo"

  echo
  echo "applied (${#APPLIED[@]}):"
  ((${#APPLIED[@]} == 0)) || printf '  - %s\n' "${APPLIED[@]}"
  echo "skipped (${#SKIPPED[@]}):"
  ((${#SKIPPED[@]} == 0)) || printf '  - %s\n' "${SKIPPED[@]}"
  echo "notes (${#NOTES[@]}):"
  ((${#NOTES[@]} == 0)) || printf '  - %s\n' "${NOTES[@]}"
  echo "failed (${#FAILED[@]}):"
  if ((${#FAILED[@]} > 0)); then
    printf '  - %s\n' "${FAILED[@]}"
    exit 1
  fi
}

main "$@"
