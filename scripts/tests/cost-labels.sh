#!/usr/bin/env bash
# Mutate a real render: missing showback metadata must fail the same contract gate.
set -euo pipefail
# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
# shellcheck source=scripts/lib/k8s.sh
source "$REPO_ROOT/scripts/lib/k8s.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
bash "$REPO_ROOT/scripts/render-k8s.sh" local >"$WORK/valid.yaml"
node "$REPO_ROOT/scripts/check-manifests.mjs" --params "$K8S_PARAMS_EXAMPLE" "local=$WORK/valid.yaml" >/dev/null
sed '/cost\.lab\/owner:/d' "$WORK/valid.yaml" >"$WORK/invalid.yaml"
if node "$REPO_ROOT/scripts/check-manifests.mjs" --params "$K8S_PARAMS_EXAMPLE" "local=$WORK/invalid.yaml" >"$WORK/failure.log" 2>&1; then
  die 'missing owner label passed the contract gate'
fi
grep -q 'mandatory showback label cost.lab/owner' "$WORK/failure.log" || {
  cat "$WORK/failure.log" >&2
  die 'mutated fixture failed for an unexpected reason'
}
echo 'PASS showback metadata: valid render accepted, missing owner rejected'
