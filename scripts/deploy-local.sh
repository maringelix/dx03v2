#!/usr/bin/env bash
# Deploys dx03v2 to the local lab of tx03v2 (kind + the full platform, docs/LAB_LOCAL.md),
# the GitOps way: images to the lab registry, rendered manifests to the GitOps repository of the lab
# git server, an Argo CD Application that syncs them. LOCAL ONLY: it never talks to Google Cloud.
# Needs kubectl, git, ssh and docker, and KUBECONFIG pointing at the lab cluster
# (tx03v2: scripts/local-lab.sh kubeconfig); any other kube context is refused.
# Environment:
#   GIT_SHA          commit to deploy (default: HEAD; the working tree must be clean unless
#                    DEPLOY_ALLOW_DIRTY=1, which the e2e uses for prebuilt images)
#   DEPLOY_IMAGES    local images to push (default: dx03v2-api:e2e and dx03v2-web:e2e; build them with
#                    `make build` or let scripts/e2e-platform.sh do it)
#   SYNC_TIMEOUT     seconds to wait for Argo CD and the rollouts (default 600)
# Steps: local contract (lab-system/lab-contract, version 1) -> push images tagged with the commit
# SHA -> ConfigMap lab-ca -> render overlays/local-platform -> commit + push to the GitOps repository
# -> Application dx03v2 (AppProject dx03v2) -> Synced/Healthy -> rollouts -> Gateway Programmed.
set -euo pipefail

# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
# shellcheck source=scripts/lib/k8s.sh
source "$REPO_ROOT/scripts/lib/k8s.sh"
export PATH="$REPO_ROOT/.tools/bin:$PATH"

NAMESPACE=dx03v2
# The kind cluster of the tx03v2 local lab: the only kube context this script deploys to.
LAB_CONTEXT=kind-tx03v2-local
CONTRACT_VERSION=2
SYNC_TIMEOUT="${SYNC_TIMEOUT:-600}"
WORK_DIR=""
GITOPS_REV=""
declare -A C=()

# Values hard-coded in deploy/k8s/components/local-platform: the copy published by tx03v2 must agree.
EXPECTED=(
  "registry=registry.tx03v2.local"
  "db.secret-name=tx03v2-lab-db-app"
  "app.admin-token-secret-name=tx03v2-lab-app-admin-token"
  "eso.cluster-secret-store=local-secrets"
  "gateway.class=istio"
  "tls.cluster-issuer=lab-ca"
  "argocd.project=dx03v2"
  "monitoring.prometheus-service-account=monitoring/kube-prometheus-stack-prometheus"
  "tracing.otlp-endpoint=http://opentelemetry-collector.monitoring.svc:4318"
)

cleanup() {
  [[ -z "$WORK_DIR" ]] || rm -rf "$WORK_DIR"
}

# require_lab_context -> refuses any kube context but the kind cluster of the tx03v2 local lab: a
# cluster of whoever runs the script (KUBECONFIG or ~/.kube/config) is never deployed to.
require_lab_context() {
  local got
  got="$(kubectl config current-context 2>/dev/null)" || got=""
  [[ "$got" == "$LAB_CONTEXT" ]] ||
    die "refusing to deploy to the kube context '${got:-none}': only $LAB_CONTEXT (the tx03v2 local lab) is allowed; first: export KUBECONFIG=\"\$(<tx03v2>/scripts/local-lab.sh kubeconfig)\""
}

read_contract() {
  local json key value entry
  json="$(kubectl -n lab-system get configmap lab-contract -o json)" ||
    die "the local contract lab-system/lab-contract is missing (run the tx03v2 local lab first)"
  # shellcheck disable=SC2016 # JavaScript template literals, not shell expansions
  while IFS=$'\t' read -r key value; do
    C[$key]="$value"
  done < <(node -e 'const d = JSON.parse(require("fs").readFileSync(0, "utf8")).data;
    for (const [k, v] of Object.entries(d)) console.log(`${k}\t${v}`);' <<<"$json")
  [[ "${C["version"]:-}" == "$CONTRACT_VERSION" ]] || die "local contract version ${C["version"]:-?}, this deploy speaks $CONTRACT_VERSION"
  for entry in "${EXPECTED[@]}"; do
    key="${entry%%=*}"
    value="${entry#*=}"
    [[ "${C[$key]:-}" == "$value" ]] || die "local contract: $key is '${C[$key]:-}', expected '$value'"
  done
  for key in registry-push network-cidr db.endpoint-ip db.ca-configmap gitops.push-url gitops.read-url gitops.push-key-secret; do
    [[ -n "${C[$key]:-}" ]] || die "local contract: $key is missing"
  done
  log "local contract v$CONTRACT_VERSION: cluster ${C["cluster-name"]}, registry ${C["registry"]} (push ${C["registry-push"]})"
}

push_images() {
  local images=${DEPLOY_IMAGES:-"dx03v2-api:e2e dx03v2-web:e2e"} src name
  for src in $images; do
    docker image inspect "$src" >/dev/null 2>&1 || die "image $src not found (run: make build)"
    name="${src%%:*}"
    name="${name#dx03v2-}"
    docker tag "$src" "${C["registry-push"]}/dx03v2/$name:$GIT_SHA"
    docker push -q "${C["registry-push"]}/dx03v2/$name:$GIT_SHA" >/dev/null
    log "pushed ${C["registry-push"]}/dx03v2/$name:$GIT_SHA (pulled in the cluster as ${C["registry"]}/dx03v2/$name)"
  done
}

copy_ca() {
  local ns name
  ns=${C["db.ca-configmap"]%%/*}
  name=${C["db.ca-configmap"]#*/}
  kubectl -n "$ns" get configmap "$name" -o jsonpath='{.data.ca\.crt}' >"$WORK_DIR/ca.crt"
  grep -q 'BEGIN CERTIFICATE' "$WORK_DIR/ca.crt" || die "the lab CA ConfigMap ${C["db.ca-configmap"]} has no certificate"
  kubectl -n "$NAMESPACE" create configmap lab-ca --from-file=ca.crt="$WORK_DIR/ca.crt" --dry-run=client -o yaml |
    kubectl apply -f - >/dev/null
}

render() {
  local params="$WORK_DIR/params.env"
  cat >"$params" <<EOF
API_IMAGE=${C["registry"]}/dx03v2/api:$GIT_SHA
WEB_IMAGE=${C["registry"]}/dx03v2/web:$GIT_SHA
NETWORK_CIDR=${C["network-cidr"]}
DB_ENDPOINT_CIDR=${C["db.endpoint-ip"]}/32
EOF
  k8s_render local-platform "" "$params" >"$WORK_DIR/dx03v2.yaml"
  log "rendered overlays/local-platform: $(grep -c '^kind:' "$WORK_DIR/dx03v2.yaml") objects"
}

publish() {
  local key="$WORK_DIR/push-key" repo="$WORK_DIR/gitops" ns name
  ns=${C["gitops.push-key-secret"]%%/*}
  name=${C["gitops.push-key-secret"]#*/}
  kubectl -n "$ns" get secret "$name" -o jsonpath='{.data.ssh-privatekey}' | base64 -d >"$key"
  chmod 600 "$key"
  export GIT_SSH_COMMAND="ssh -i $key -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=$WORK_DIR/known_hosts"
  if ! git clone -q "${C["gitops.read-url"]}" "$repo" 2>/dev/null; then
    git init -q -b main "$repo"
  fi
  git -C "$repo" config user.email you@example.com
  git -C "$repo" config user.name "dx03v2 deploy-local"
  cp "$WORK_DIR/dx03v2.yaml" "$repo/dx03v2.yaml"
  git -C "$repo" add dx03v2.yaml
  if git -C "$repo" diff --cached --quiet; then
    log "GitOps repository already at this revision"
  else
    git -C "$repo" commit -qm "deploy dx03v2 $GIT_SHA"
  fi
  git -C "$repo" push -q "${C["gitops.push-url"]}" HEAD:main
  GITOPS_REV="$(git -C "$repo" rev-parse HEAD)"
  log "GitOps repository ${C["gitops.read-url"]} at ${GITOPS_REV:0:7}"
}

application() {
  kubectl apply -f - >/dev/null <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: dx03v2
  namespace: argocd
spec:
  project: ${C["argocd.project"]}
  source:
    repoURL: ${C["gitops.read-url"]}
    targetRevision: main
    path: .
  destination:
    server: https://kubernetes.default.svc
    namespace: $NAMESPACE
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    retry:
      limit: 10
      backoff:
        duration: 10s
        factor: 2
        maxDuration: 2m
EOF
  kubectl -n argocd annotate application dx03v2 argocd.argoproj.io/refresh=normal --overwrite >/dev/null
}

# Synced and Healthy at the commit just pushed: on a redeploy the Application is already Synced (at the
# previous commit) until Argo CD fetches the new one.
wait_sync() {
  local i sync health rev=""
  for i in $(seq 1 $((SYNC_TIMEOUT / 5))); do
    sync="$(kubectl -n argocd get application dx03v2 -o jsonpath='{.status.sync.status}' 2>/dev/null)" || sync=""
    health="$(kubectl -n argocd get application dx03v2 -o jsonpath='{.status.health.status}' 2>/dev/null)" || health=""
    rev="$(kubectl -n argocd get application dx03v2 -o jsonpath='{.status.sync.revision}' 2>/dev/null)" || rev=""
    [[ "$sync" == Synced && "$health" == Healthy && "$rev" == "$GITOPS_REV" ]] && {
      log "Argo CD: dx03v2 Synced and Healthy at ${rev:0:7}"
      return 0
    }
    ((i % 12 == 0)) && log "Argo CD: dx03v2 sync=${sync:-?} health=${health:-?}"
    sleep 5
  done
  kubectl -n argocd get application dx03v2 -o jsonpath='{range .status.conditions[*]}{.type}: {.message}{"\n"}{end}' >&2 || :
  die "Argo CD did not reach Synced/Healthy within ${SYNC_TIMEOUT}s"
}

wait_for_image() {
  local deploy="$1" expected="${C["registry"]}/dx03v2/$1:$GIT_SHA" actual="" attempt
  for attempt in $(seq 1 $((SYNC_TIMEOUT / 5))); do
    actual="$(kubectl -n "$NAMESPACE" get deployment "$deploy" -o jsonpath='{.spec.template.spec.containers[0].image}')"
    [[ "$actual" == "$expected" ]] && return 0
    sleep 5
  done
  die "rollout: deployment/$deploy still uses ${actual:-no image}; expected $expected"
}

wait_workloads() {
  local ip
  kubectl -n "$NAMESPACE" wait --for=condition=Ready externalsecret/db-credentials externalsecret/app-secrets --timeout=180s >/dev/null
  wait_for_image api
  kubectl -n "$NAMESPACE" rollout status deployment/api --timeout="${SYNC_TIMEOUT}s"
  wait_for_image web
  kubectl -n "$NAMESPACE" rollout status deployment/web --timeout="${SYNC_TIMEOUT}s"
  kubectl -n "$NAMESPACE" wait --for=condition=Programmed gateway/dx03v2 --timeout="${SYNC_TIMEOUT}s" >/dev/null
  ip="$(kubectl -n "$NAMESPACE" get gateway dx03v2 -o jsonpath='{.status.addresses[0].value}')"
  log "Gateway dx03v2 Programmed at $ip (https://dx03v2.tx03v2.local)"
}

main() {
  require_cmd kubectl git ssh docker node base64
  require_lab_context
  kubectl version >/dev/null 2>&1 || die "the lab cluster is not reachable (KUBECONFIG=${KUBECONFIG:-unset})"
  if [[ -z "${GIT_SHA:-}" ]]; then
    GIT_SHA="$(git -C "$REPO_ROOT" rev-parse HEAD)"
    if [[ "${DEPLOY_ALLOW_DIRTY:-0}" != 1 && -n "$(git -C "$REPO_ROOT" status --porcelain)" ]]; then
      die "the working tree is not clean: commit first (or set GIT_SHA)"
    fi
  fi
  [[ "$GIT_SHA" =~ ^[0-9a-f]{40}$ ]] || die "GIT_SHA must be a 40-character commit SHA"
  WORK_DIR="$(mktemp -d)"
  chmod 700 "$WORK_DIR"
  trap cleanup EXIT
  read_contract
  push_images
  copy_ca
  render
  publish
  application
  wait_sync
  wait_workloads
}

main "$@"
