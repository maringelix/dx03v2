#!/usr/bin/env bash
# Deploys dx03v2 to the GKE Autopilot lab cluster of tx03v2 (docs/CONTRATO.md).
# CLOUD-MUTATING and billable: pushes images to Artifact Registry and makes the GKE Gateway
# controller program a global external Application Load Balancer (forwarding rule, backend
# services, NEGs and, with the WAF, the Cloud Armor policy of tx03v2), which with Cloud SQL is the
# biggest cost item of the Google Cloud lab. Run it only on purpose, after the tx03v2 apply +
# platform steps; the teardown is the tx03v2 destroy (its platform/uninstall.sh deletes the
# namespace first, so the load balancer of the Gateway never leaks).
# Not run in the cloud yet (v2).
# Used by .github/workflows/deploy-gcp.yml and from a laptop (docs/RUNBOOK.md):
#   gcloud auth login && GCP_PROJECT_ID=tx03v2-lab-example scripts/deploy-gcp.sh
# Environment:
#   GCP_PROJECT_ID      required: the project of the lab (the script never guesses it)
#   GIT_SHA             commit to deploy (default: HEAD); must be the checked-out commit, and the
#                       working tree must be clean (the images are tagged with it)
#   SMOKE_WAIT_SECONDS  how long the smoke test waits for the load balancer (default 900)
# Steps: Parameter Manager contract (tx03v2-lab-contract) -> GKE kubeconfig (DNS endpoint,
# gke-gcloud-auth-plugin) -> API groups, GatewayClass and RBAC preflight -> Artifact Registry
# login and tag check -> images (linux/amd64 build + push; an existing tag is never pushed again)
# -> ConfigMap cloudsql-ca (regional Cloud SQL CA bundle, contract root checked) -> render +
# kubectl apply -k -> ExternalSecrets -> rollouts -> Gateway programmed on the contract address ->
# smoke test through the load balancer -> job summary (GitHub Actions).
# gcloud is the only credential holder: in GitHub Actions google-github-actions/auth writes a
# Workload Identity Federation credentials file that gcloud refreshes for the whole job, and kubectl
# gets its tokens from gcloud through gke-gcloud-auth-plugin.
set -euo pipefail

# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
# shellcheck source=scripts/lib/k8s.sh
source "$REPO_ROOT/scripts/lib/k8s.sh"
export PATH="$REPO_ROOT/.tools/bin:$PATH"

NAMESPACE=dx03v2
CONTRACT_PARAMETER=tx03v2-lab-contract
# Contract: the exact key set of the parameter (the harness check contract-app verifies this list).
CONTRACT_KEYS=(
  project-id region cluster-name network-name nodes-subnet-cidr db/endpoint-ip lb-source-ranges
  artifact-registry/repository db/secret-name app/admin-token-secret-name eso/cluster-secret-store
  gateway/address-name gateway/address waf/security-policy deploy/service-account
)
# Values fixed in deploy/k8s/components/gcp and in this script: the parameter of tx03v2 must agree.
CONTRACT_CLUSTER=tx03v2-lab
CONTRACT_NETWORK=tx03v2-lab
CONTRACT_DB_SECRET=tx03v2-lab-db-app
CONTRACT_ADMIN_TOKEN_SECRET=tx03v2-lab-app-admin-token
CONTRACT_SECRET_STORE=gcp-secret-manager
CONTRACT_ADDRESS_NAME=tx03v2-lab-gateway
CONTRACT_LB_SOURCE_RANGES=35.191.0.0/16,130.211.0.0/22
CONTRACT_WAF_POLICY=tx03v2-lab-waf
CONTRACT_DEPLOY_ACCOUNT=dx03v2-gha-deploy
GATEWAY_CLASS=gke-l7-global-external-managed
# Contract: the regional bundles of the shared Cloud SQL CAs (GOOGLE_MANAGED_CAS_CA) are public.
# The bundle must hold exactly one self-signed root, with this SHA-256, and only CAs issued by it.
# The file itself is never pinned: the subordinate CAs of a region rotate.
CLOUDSQL_CA_URL_BASE=https://storage.googleapis.com/cloudsql-ca-bundles
CLOUDSQL_ROOT_SHA256=C7B0FCD282B346F1FCC45EE8A79ECF6EF6FAEF2D669BEEC664293B93D83E59BE
# Contract: Autopilot runs x86-64 nodes (general-purpose class): the images target linux/amd64.
IMAGE_PLATFORM=linux/amd64
IPV4="$K8S_IPV4_OCTET(\.$K8S_IPV4_OCTET){3}"
# The kinds the overlays write, as Kubernetes resources (Role dx03v2-deployer of tx03v2). The
# GCPBackendPolicies are written by gcp-waf and deleted by gcp, so they are always required.
DEPLOY_RESOURCES=(
  deployments.apps services configmaps serviceaccounts poddisruptionbudgets.policy
  horizontalpodautoscalers.autoscaling networkpolicies.networking.k8s.io gateways.gateway.networking.k8s.io
  httproutes.gateway.networking.k8s.io healthcheckpolicies.networking.gke.io
  gcpbackendpolicies.networking.gke.io externalsecrets.external-secrets.io
)
# Read-only rules of the Role that the rollout, the waits and the smoke test use.
READ_RESOURCES=(secrets pods pods/log events replicasets.apps)

declare -A PARAM=()
declare -a TO_BUILD=()
WORK_DIR=""
GROUP_OPEN=0
OVERLAY=gcp-waf
REGISTRY_HOST=""
REGISTRY_LOGGED_IN=0
API_IMAGE=""
WEB_IMAGE=""
GATEWAY_ADDRESS=""
BASE=""

in_actions() { [[ "${GITHUB_ACTIONS:-}" == true ]]; }

# mask VALUE -> hides an identifier (project ID, service account e-mail) or the admin token in the
# GitHub Actions logs, which are public for a public repository.
mask() {
  if in_actions && [[ -n "$1" ]]; then
    echo "::add-mask::$1"
  fi
}

section() {
  if in_actions; then
    ((GROUP_OPEN == 0)) || echo "::endgroup::"
    echo "::group::$*"
    GROUP_OPEN=1
  else
    log "== $*"
  fi
}

param() { printf '%s' "${PARAM[$1]}"; }

# expect_param KEY VALUE -> the fixed names of the contract (never identifiers, safe to print).
expect_param() {
  [[ "$(param "$1")" == "$2" ]] ||
    die "contract key $1 is '$(param "$1")' but the manifests expect '$2' (docs/CONTRATO.md)"
}

# expect_format KEY REGEX -> values that carry identifiers are validated without printing them.
expect_format() {
  [[ "$(param "$1")" =~ $2 ]] ||
    die "contract key $1 of $CONTRACT_PARAMETER does not have the format of the contract (docs/CONTRATO.md)"
}

ipv4_to_int() {
  local a b c d
  IFS=. read -r a b c d <<<"$1"
  printf '%s' "$(((a << 24) | (b << 16) | (c << 8) | d))"
}

# ipv4_in_cidr IP CIDR -> true when IP lies inside CIDR (both already format-checked).
ipv4_in_cidr() {
  local ip net len mask
  ip="$(ipv4_to_int "$1")"
  net="$(ipv4_to_int "${2%/*}")"
  len=${2#*/}
  mask=$(((0xFFFFFFFF << (32 - len)) & 0xFFFFFFFF))
  (((ip & mask) == (net & mask)))
}

write_summary() { # RESULT
  [[ -n "${GITHUB_STEP_SUMMARY:-}" ]] || return 0
  {
    echo "## dx03v2 deploy: $1"
    echo
    echo "| Item | Value |"
    echo "|---|---|"
    echo "| Commit | \`${GIT_SHA:-unknown}\` |"
    echo "| Overlay | \`deploy/k8s/overlays/$OVERLAY\` |"
    echo "| Images | \`dx03v2/api:${GIT_SHA:-}\`, \`dx03v2/web:${GIT_SHA:-}\` in Artifact Registry |"
    echo "| Entry point | ${BASE:-not reached} |"
    if [[ -f "$WORK_DIR/smoke.txt" ]]; then
      echo
      echo '```'
      cat "$WORK_DIR/smoke.txt"
      echo '```'
    fi
    echo
    echo "The GKE cluster, Cloud SQL and the load balancer of the Gateway (with Cloud Armor) bill by the hour: tear the lab down with the destroy workflow of tx03v2."
  } >>"$GITHUB_STEP_SUMMARY"
}

cleanup() {
  local rc=$?
  if ((GROUP_OPEN)); then
    echo "::endgroup::"
  fi
  if ((REGISTRY_LOGGED_IN)); then
    docker logout "https://$REGISTRY_HOST" >/dev/null 2>&1 || :
  fi
  if [[ -n "$WORK_DIR" ]]; then
    if ((rc == 0)); then
      write_summary succeeded
    else
      write_summary failed
    fi
    rm -rf "$WORK_DIR"
  fi
  exit "$rc"
}

preflight() {
  local head account
  require_cmd gcloud gke-gcloud-auth-plugin kubectl docker node git curl base64 openssl awk
  [[ -n "${GCP_PROJECT_ID:-}" ]] || die "GCP_PROJECT_ID is required (the project of the lab; the script never guesses it)"
  [[ "$GCP_PROJECT_ID" =~ ^$K8S_GCP_PROJECT$ ]] || die "GCP_PROJECT_ID is not a Google Cloud project ID"
  mask "$GCP_PROJECT_ID"
  [[ -z "$(git -C "$REPO_ROOT" status --porcelain)" ]] ||
    die "the working tree has uncommitted changes: the images are built from it and tagged with the commit SHA"
  head="$(git -C "$REPO_ROOT" rev-parse HEAD)"
  GIT_SHA="${GIT_SHA:-$head}"
  [[ "$GIT_SHA" =~ ^[0-9a-f]{40}$ ]] || die "GIT_SHA must be a full 40-character commit SHA"
  [[ "$GIT_SHA" == "$head" ]] || die "GIT_SHA must be the checked-out commit (the images are built from the working tree)"
  account="$(gcloud auth list --filter=status:ACTIVE --format='value(account)')" ||
    die "cannot query the gcloud credentials"
  [[ -n "$account" ]] ||
    die "gcloud has no active credential (google-github-actions/auth with dx03v2-gha-deploy in GitHub Actions, or gcloud auth login)"
  mask "$account"
}

read_contract() {
  local payload json lines key value n
  payload="$(gcloud parametermanager parameters versions render latest --parameter="$CONTRACT_PARAMETER" \
    --location=global --project="$GCP_PROJECT_ID" --format='value(renderedPayload)')" ||
    die "cannot render $CONTRACT_PARAMETER (is tx03v2 applied, and does this identity have roles/parametermanager.parameterAccessor?)"
  json="$(printf '%s' "$payload" | base64 -d)" || die "the payload of $CONTRACT_PARAMETER is not base64"
  # A flat JSON object of strings with exactly the contract keys (no more, no less).
  # shellcheck disable=SC2016 # JavaScript template literals, not shell expansions
  lines="$(node -e '
    let s = "";
    process.stdin.on("data", (d) => (s += d)).on("end", () => {
      let doc;
      try {
        doc = JSON.parse(s);
      } catch {
        console.error("the contract is not JSON");
        process.exit(3);
      }
      if (doc === null || typeof doc !== "object" || Array.isArray(doc)) {
        console.error("the contract is not a JSON object");
        process.exit(3);
      }
      const want = process.argv.slice(1);
      const got = Object.keys(doc);
      const extra = got.filter((k) => !want.includes(k));
      const missing = want.filter((k) => !got.includes(k));
      if (extra.length || missing.length) {
        console.error(`the contract keys differ from docs/CONTRATO.md: missing [${missing}], unknown [${extra}]`);
        process.exit(3);
      }
      for (const [k, v] of Object.entries(doc)) {
        if (typeof v !== "string" || v === "" || /[\t\n\r]/.test(v)) {
          console.error(`the contract key ${k} is not a non-empty single-line string`);
          process.exit(3);
        }
        console.log(`${k}\t${v}`);
      }
    });' "${CONTRACT_KEYS[@]}" <<<"$json")" || die "$CONTRACT_PARAMETER does not hold the contract key set (docs/CONTRATO.md)"
  while IFS=$'\t' read -r key value; do
    if [[ -n "$key" ]]; then
      PARAM[$key]=$value
    fi
  done <<<"$lines"
  for n in "${CONTRACT_KEYS[@]}"; do
    [[ -n "${PARAM[$n]:-}" ]] || die "the contract key $n is missing in $CONTRACT_PARAMETER (docs/CONTRATO.md)"
  done
  mask "$(param deploy/service-account)"
  [[ "$(param project-id)" == "$GCP_PROJECT_ID" ]] ||
    die "contract key project-id is not GCP_PROJECT_ID (the parameter belongs to another project)"
  expect_param cluster-name "$CONTRACT_CLUSTER"
  expect_param network-name "$CONTRACT_NETWORK"
  expect_param db/secret-name "$CONTRACT_DB_SECRET"
  expect_param app/admin-token-secret-name "$CONTRACT_ADMIN_TOKEN_SECRET"
  expect_param eso/cluster-secret-store "$CONTRACT_SECRET_STORE"
  expect_param gateway/address-name "$CONTRACT_ADDRESS_NAME"
  expect_param lb-source-ranges "$CONTRACT_LB_SOURCE_RANGES"
  expect_format region "^$K8S_GCP_REGION\$"
  expect_format nodes-subnet-cidr "^$IPV4/([89]|1[0-9]|2[0-9])\$"
  expect_format db/endpoint-ip "${K8S_PARAM_PATTERN[DB_ENDPOINT_IP]}"
  expect_format gateway/address "^$IPV4\$"
  expect_format waf/security-policy "^($CONTRACT_WAF_POLICY|none)\$"
  expect_format deploy/service-account "^$CONTRACT_DEPLOY_ACCOUNT@$GCP_PROJECT_ID\\.iam\\.gserviceaccount\\.com\$"
  # The nodes subnet is RFC 1918 (validated by tx03v2) and the Private Service Connect endpoint of
  # Cloud SQL is one of its addresses: the egress NetworkPolicy allows exactly that /32.
  [[ "$(param nodes-subnet-cidr)" =~ ${K8S_PARAM_PATTERN[DB_ENDPOINT_IP]%\$}/ ]] ||
    die "contract key nodes-subnet-cidr is not an RFC 1918 range (docs/CONTRATO.md)"
  ipv4_in_cidr "$(param db/endpoint-ip)" "$(param nodes-subnet-cidr)" ||
    die "contract key db/endpoint-ip is not inside nodes-subnet-cidr (the Cloud SQL endpoint is an address of the nodes subnet)"
  REGISTRY_HOST="$(param region)-docker.pkg.dev"
  [[ "$(param artifact-registry/repository)" == "$REGISTRY_HOST/$GCP_PROJECT_ID/dx03v2" ]] ||
    die "contract key artifact-registry/repository is not <region>-docker.pkg.dev/<project>/dx03v2 (docs/CONTRATO.md)"
  if [[ "$(param waf/security-policy)" == none ]]; then
    OVERLAY=gcp
  fi
  API_IMAGE="$(param artifact-registry/repository)/api:$GIT_SHA"
  WEB_IMAGE="$(param artifact-registry/repository)/web:$GIT_SHA"
  log "contract: ${#CONTRACT_KEYS[@]} keys read and consistent with the manifests (overlay $OVERLAY)"
}

# connect_cluster -> temporary kubeconfig, then proof that the platform layer of tx03v2 is there and
# that this identity may write every kind of the overlay (fails before anything is built or pushed).
connect_cluster() {
  local versions resource verb
  local -a missing=()
  export KUBECONFIG="$WORK_DIR/kubeconfig"
  # The control plane has no public IP endpoint: the DNS endpoint authorizes every request with IAM
  # (roles/container.clusterViewer of the contract); kubectl authenticates through gke-gcloud-auth-plugin.
  gcloud container clusters get-credentials "$(param cluster-name)" --location "$(param region)" \
    --project "$GCP_PROJECT_ID" --dns-endpoint >/dev/null ||
    die "cannot fetch the credentials of $(param cluster-name) (this identity needs roles/container.clusterViewer, docs/CONTRATO.md)"
  # Discovery is open to every authenticated user: the API groups of the platform layer must be served.
  versions="$(kubectl api-versions)" || die "cannot reach the API server of $(param cluster-name) with this identity"
  for resource in gateway.networking.k8s.io/v1 networking.gke.io/v1 external-secrets.io/v1; do
    grep -qxF "$resource" <<<"$versions" || missing+=("$resource")
  done
  ((${#missing[@]} == 0)) ||
    die "the cluster does not serve ${missing[*]}: Gateway API on the cluster (tx03v2) and the External Secrets Operator of the tx03v2 platform layer"
  # GatewayClasses are cluster-scoped and outside the Role of the deployer: checked when readable,
  # otherwise the Gateway condition Programmed (below) is what proves the class.
  if [[ "$(kubectl auth can-i get gatewayclasses.gateway.networking.k8s.io 2>/dev/null)" == yes ]]; then
    kubectl get gatewayclass "$GATEWAY_CLASS" -o name >/dev/null ||
      die "the GatewayClass $GATEWAY_CLASS is missing (Gateway API of the GKE cluster of tx03v2)"
    log "GatewayClass $GATEWAY_CLASS present"
  else
    log "GatewayClass $GATEWAY_CLASS not readable with this identity (cluster scope): the Gateway condition Programmed proves it"
  fi
  for resource in "${DEPLOY_RESOURCES[@]}"; do
    for verb in get watch create patch delete; do
      [[ "$(kubectl auth can-i "$verb" "$resource" -n "$NAMESPACE" 2>/dev/null)" == yes ]] || missing+=("$verb $resource")
    done
  done
  for resource in "${READ_RESOURCES[@]}"; do
    [[ "$(kubectl auth can-i get "$resource" -n "$NAMESPACE" 2>/dev/null)" == yes ]] || missing+=("get $resource")
  done
  ((${#missing[@]} == 0)) ||
    die "this identity cannot deploy to namespace $NAMESPACE (${missing[*]}): it needs the RoleBinding dx03v2-deployers of the tx03v2 platform layer (Role dx03v2-deployer; subject: the e-mail of dx03v2-gha-deploy, or yours in app_deployer_members)"
  log "cluster $(param cluster-name): platform API groups served, Role dx03v2-deployer usable in $NAMESPACE"
}

# prepare_images -> docker login to Artifact Registry and the list of images to build. The
# repository has immutable tags: an existing tag is reused as is, never pushed again.
prepare_images() {
  local packages tags component
  gcloud auth print-access-token | docker login -u oauth2accesstoken --password-stdin "https://$REGISTRY_HOST" >/dev/null ||
    die "docker login to $REGISTRY_HOST failed (this identity needs roles/artifactregistry.writer on dx03v2, docs/CONTRATO.md)"
  REGISTRY_LOGGED_IN=1
  # Names and tags may come back as full resource paths: only the last segment is compared.
  packages="$(gcloud artifacts packages list --repository=dx03v2 --location="$(param region)" \
    --project="$GCP_PROJECT_ID" --format='value(name)' | awk -F/ '{ print $NF }')" ||
    die "cannot list the packages of the Artifact Registry repository dx03v2"
  for component in api web; do
    tags=""
    if grep -qxF "$component" <<<"$packages"; then
      tags="$(gcloud artifacts docker tags list "$(param artifact-registry/repository)/$component" \
        --format='value(tag)' | awk -F/ '{ print $NF }')" || die "cannot list the tags of dx03v2/$component"
    fi
    if grep -qxF "$GIT_SHA" <<<"$tags"; then
      log "dx03v2/$component:$GIT_SHA is already in Artifact Registry: reused, never pushed again"
    else
      TO_BUILD+=("$component")
    fi
  done
}

publish_images() {
  local component image
  for component in "${TO_BUILD[@]}"; do
    image="$API_IMAGE"
    if [[ "$component" == web ]]; then
      image="$WEB_IMAGE"
    fi
    docker buildx build --platform "$IMAGE_PLATFORM" -f "$REPO_ROOT/$component/Dockerfile" \
      --build-arg GIT_SHA="$GIT_SHA" -t "$image" --push "$REPO_ROOT"
  done
  log "images: built and pushed ${TO_BUILD[*]:-nothing}; deploying dx03v2/api and dx03v2/web at $GIT_SHA"
}

# create_cloudsql_ca -> ConfigMap cloudsql-ca with the regional CA bundle of Cloud SQL, after
# proving that it holds exactly one self-signed root (the contract SHA-256) and only CAs issued by
# it. The ConfigMap gets the certificates re-encoded by openssl, nothing else of the download.
create_cloudsql_ca() {
  local url raw="$WORK_DIR/cloudsql-ca-download.pem" dir="$WORK_DIR/cloudsql-ca" bundle="$WORK_DIR/cloudsql-ca.pem"
  local cert fp subject issuer root="" root_fp="" root_subject="" roots=0 subs=0
  local -a certs=()
  url="$CLOUDSQL_CA_URL_BASE/$(param region).pem"
  download "$url" "$raw"
  if grep -E '^-----BEGIN ' "$raw" | grep -qvxE -- '-----BEGIN CERTIFICATE-----'; then
    die "refusing $url: it holds PEM blocks other than certificates"
  fi
  mkdir -p "$dir"
  awk -v dir="$dir" '
    /^-----BEGIN CERTIFICATE-----$/ { n++; out = sprintf("%s/cert-%03d.pem", dir, n); inside = 1 }
    inside { print > out }
    /^-----END CERTIFICATE-----$/ { inside = 0; close(out) }' "$raw"
  mapfile -t certs < <(find "$dir" -name 'cert-*.pem' | sort)
  ((${#certs[@]} > 0)) || die "refusing $url: no certificate in it"
  for cert in "${certs[@]}"; do
    fp="$(openssl x509 -in "$cert" -noout -fingerprint -sha256)" || die "refusing $url: unreadable certificate"
    fp="${fp#*=}"
    fp="${fp//:/}"
    subject="$(openssl x509 -in "$cert" -noout -subject -nameopt RFC2253)"
    issuer="$(openssl x509 -in "$cert" -noout -issuer -nameopt RFC2253)"
    if [[ "${subject#subject=}" == "${issuer#issuer=}" ]]; then
      roots=$((roots + 1))
      root="$cert"
      root_fp="${fp^^}"
      root_subject="${subject#subject=}"
    fi
  done
  ((roots == 1)) || die "refusing $url: $roots self-signed certificates, the contract expects exactly one root"
  [[ "$root_fp" == "$CLOUDSQL_ROOT_SHA256" ]] ||
    die "refusing $url: the root $root_subject has SHA-256 $root_fp, the contract expects $CLOUDSQL_ROOT_SHA256"
  # Only the root is trusted (no system store): a self-signature or an issuer outside the bundle fails.
  openssl verify -no-CApath -no-CAstore -x509_strict -CAfile "$root" "$root" >/dev/null ||
    die "refusing $url: the root does not verify (signature or validity)"
  : >"$bundle"
  openssl x509 -in "$root" >>"$bundle"
  for cert in "${certs[@]}"; do
    [[ "$cert" != "$root" ]] || continue
    openssl x509 -in "$cert" -noout -ext basicConstraints 2>/dev/null | grep -q 'CA:TRUE' ||
      die "refusing $url: $(openssl x509 -in "$cert" -noout -subject -nameopt RFC2253) is not a CA certificate"
    openssl verify -no-CApath -no-CAstore -x509_strict -CAfile "$root" "$cert" >/dev/null ||
      die "refusing $url: $(openssl x509 -in "$cert" -noout -subject -nameopt RFC2253) is not issued by the contract root"
    openssl x509 -in "$cert" >>"$bundle"
    subs=$((subs + 1))
  done
  log "Cloud SQL CA bundle of $(param region): root SHA-256 $CLOUDSQL_ROOT_SHA256 and $subs subordinate CAs verified"
  kubectl -n "$NAMESPACE" create configmap cloudsql-ca --from-file=ca.pem="$bundle" --dry-run=client -o yaml |
    kubectl apply -f -
}

render_and_apply() {
  local params="$WORK_DIR/params.env" tree="$WORK_DIR/k8s"
  {
    echo "API_IMAGE=$API_IMAGE"
    echo "WEB_IMAGE=$WEB_IMAGE"
    echo "GATEWAY_ADDRESS_NAME=$(param gateway/address-name)"
    echo "WAF_SECURITY_POLICY=$(param waf/security-policy)"
    echo "LB_SOURCE_RANGES=$(param lb-source-ranges)"
    echo "DB_ENDPOINT_IP=$(param db/endpoint-ip)"
  } >"$params"
  # Validates every value against the contract formats and renders a temporary copy of deploy/k8s.
  k8s_prepare_tree "$tree" "$params"
  kubectl kustomize "$tree/overlays/$OVERLAY" >"$WORK_DIR/rendered.yaml"
  log "overlays/$OVERLAY rendered: $(grep -c '^kind: ' "$WORK_DIR/rendered.yaml") objects"
  kubectl apply -k "$tree/overlays/$OVERLAY"
  if [[ "$OVERLAY" == gcp ]]; then
    # waf/security-policy is none: policies left by an earlier deploy would name a deleted Cloud Armor policy.
    kubectl -n "$NAMESPACE" delete gcpbackendpolicies.networking.gke.io api web --ignore-not-found
  fi
}

wait_for_rollout() {
  if ! kubectl -n "$NAMESPACE" wait externalsecret/db-credentials externalsecret/app-secrets \
    --for=condition=Ready --timeout=300s; then
    kubectl -n "$NAMESPACE" describe externalsecret db-credentials app-secrets >&2 || :
    die "the ExternalSecrets did not become Ready (ClusterSecretStore $CONTRACT_SECRET_STORE and the Secret Manager secrets of tx03v2)"
  fi
  kubectl -n "$NAMESPACE" rollout status deployment/api --timeout=600s
  kubectl -n "$NAMESPACE" rollout status deployment/web --timeout=600s
}

wait_for_gateway() {
  local route policies
  if ! kubectl -n "$NAMESPACE" wait gateway/dx03v2 --for=condition=Programmed --timeout=900s; then
    kubectl -n "$NAMESPACE" describe gateway dx03v2 >&2 || :
    die "the Gateway was not programmed in 15 minutes (GatewayClass $GATEWAY_CLASS, the address $(param gateway/address-name) of tx03v2; see the events above)"
  fi
  GATEWAY_ADDRESS="$(kubectl -n "$NAMESPACE" get gateway dx03v2 -o jsonpath='{.status.addresses[0].value}')"
  [[ "$GATEWAY_ADDRESS" == "$(param gateway/address)" ]] ||
    die "the programmed Gateway is not on the contract address gateway/address (got '${GATEWAY_ADDRESS:-none}')"
  route="$(kubectl -n "$NAMESPACE" get httproute dx03v2 -o jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}')"
  policies="$(kubectl -n "$NAMESPACE" get healthcheckpolicies.networking.gke.io,gcpbackendpolicies.networking.gke.io \
    -o jsonpath='{range .items[*]}{.kind}/{.metadata.name}:{range .status.conditions[*]}{.type}={.status},{end} {end}')"
  log "Gateway programmed at $GATEWAY_ADDRESS; HTTPRoute accepted: ${route:-unknown}; policies: ${policies:-none}"
}

smoke() {
  local token status=0
  BASE="http://$GATEWAY_ADDRESS"
  token="$(kubectl -n "$NAMESPACE" get secret app-secrets -o jsonpath='{.data.ADMIN_TOKEN}' | base64 -d)"
  [[ ${#token} -ge 32 ]] || die "the Secret app-secrets has no usable ADMIN_TOKEN (is the ExternalSecret synced?)"
  mask "$token"
  # SMOKE_EDGE=gke: the HTTPRoute sends /api straight to the API; Cloud Armor inspects the first
  # 64 KB and never blocks for size, so the API itself answers 413 for the 70 KB body.
  BASE_URL="$BASE" ADMIN_TOKEN="$token" SMOKE_EDGE=gke SMOKE_WAIT_SECONDS="${SMOKE_WAIT_SECONDS:-900}" \
    node "$REPO_ROOT/e2e/smoke.mjs" | tee "$WORK_DIR/smoke.txt" || status=$?
  ((status == 0)) || die "the smoke test through the load balancer of the Gateway failed (FAIL lines above)"
}

main() {
  (($# == 0)) || die "usage: $0 (configuration through environment variables, see the header)"
  preflight
  WORK_DIR="$(mktemp -d)"
  trap cleanup EXIT
  section "contract: Parameter Manager $CONTRACT_PARAMETER"
  read_contract
  section "cluster $(param cluster-name): kubeconfig, platform API groups, RBAC"
  connect_cluster
  section "Artifact Registry $REGISTRY_HOST: login and existing tags"
  prepare_images
  section "images dx03v2/api and dx03v2/web, tag $GIT_SHA"
  publish_images
  section "ConfigMap cloudsql-ca (Cloud SQL CA bundle, contract root checked)"
  create_cloudsql_ca
  section "kubectl apply -k deploy/k8s/overlays/$OVERLAY"
  render_and_apply
  section "ExternalSecrets and rollouts"
  wait_for_rollout
  section "Gateway (global external Application Load Balancer)"
  wait_for_gateway
  section "smoke test through the load balancer"
  smoke
  log "deploy of $GIT_SHA complete: $BASE"
}

main "$@"
