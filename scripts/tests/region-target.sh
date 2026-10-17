#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
# shellcheck source=scripts/lib/k8s.sh
source "$REPO_ROOT/scripts/lib/k8s.sh"
# shellcheck source=scripts/lib/region-target.sh
source "$REPO_ROOT/scripts/lib/region-target.sh"
export PATH="$REPO_ROOT/.tools/bin:$PATH"
select_region_target primary
[[ "$CONTRACT_PARAMETER" == tx03v2-lab-contract && "$GITOPS_BRANCH" == gitops/gcp ]]
select_region_target secondary
[[ "$CONTRACT_PARAMETER" == tx03v2-lab-dr-contract && "$GITOPS_BRANCH" == gitops/gcp-dr ]]
[[ "$CONTRACT_CLUSTER" == tx03v2-lab-dr && "$CONTRACT_NETWORK" == tx03v2-lab-dr ]]
[[ "$CONTRACT_DB_SECRET" == tx03v2-lab-dr-db-app ]]
[[ "$CONTRACT_ADMIN_TOKEN_SECRET" == tx03v2-lab-dr-app-admin-token ]]
[[ "$CONTRACT_ADDRESS_NAME" == tx03v2-lab-dr-gateway ]]
if (select_region_target user-cluster) >/dev/null 2>&1; then die 'arbitrary target accepted'; fi
work="$(mktemp -d)"
cleanup() { rm -rf -- "${work:?}"; }
trap cleanup EXIT
sed -e 's/us-central1/us-east1/g' \
  -e 's/DB_SECRET_NAME=tx03v2-lab-/DB_SECRET_NAME=tx03v2-lab-dr-/' \
  -e 's/ADMIN_TOKEN_SECRET_NAME=tx03v2-lab-/ADMIN_TOKEN_SECRET_NAME=tx03v2-lab-dr-/' \
  -e 's/GATEWAY_ADDRESS_NAME=tx03v2-lab-/GATEWAY_ADDRESS_NAME=tx03v2-lab-dr-/' \
  "$K8S_PARAMS_EXAMPLE" >"$work/params.env"
k8s_render gcp-waf-full "$work/params.env" >"$work/rendered.yaml"
k8s_render gcp-waf-full >"$work/example.yaml"
node "$REPO_ROOT/scripts/render-gitops-application.mjs" gcp gcp-waf-full \
  "$work/params.env" "$K8S_PARAMS_EXAMPLE" >"$work/application.json"
node "$REPO_ROOT/scripts/check-gitops-renderer.mjs" "$work/application.json" "$work/example.yaml"
node --input-type=module - "$work/rendered.yaml" "$work/application.json" <<'JS'
import fs from 'node:fs';
import assert from 'node:assert/strict';
import {parseAllDocuments} from 'yaml';
const docs = parseAllDocuments(fs.readFileSync(process.argv[2], 'utf8')).map(d => d.toJS()).filter(Boolean);
const app = JSON.parse(fs.readFileSync(process.argv[3], 'utf8'));
assert.equal(app.spec.source.targetRevision, 'gitops/gcp-dr');
const external = docs.filter(d => d.kind === 'ExternalSecret');
assert.equal(external.length, 2);
for (const resource of external) {
  const expected = resource.metadata.name === 'db-credentials' ? 'tx03v2-lab-dr-db-app' : 'tx03v2-lab-dr-app-admin-token';
  for (const item of resource.spec.data) assert.equal(item.remoteRef.key, expected);
}
assert.equal(docs.find(d => d.kind === 'Gateway').spec.addresses[0].value, 'tx03v2-lab-dr-gateway');
JS
echo 'PASS regional deploy: secondary contract, endpoint, secret references, images and separate GitOps branch'
