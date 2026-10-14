#!/usr/bin/env bash
# The app on the full local platform of tx03v2 (harness stage platform, CI job e2e-platform). Steps:
#   1. tx03v2 at the pinned commit (deploy/local/tx03v2.ref) or TX03V2_DIR: scripts/local-lab.sh up
#   2. build dx03v2-api:e2e / dx03v2-web:e2e (skipped with E2E_SKIP_BUILD=1)
#   3. scripts/deploy-local.sh: registry, GitOps repository, Argo CD sync
#   4. probes of the app on the platform (below), every one with real traffic or API calls
#   5. tx03v2 scripts/local-lab.sh down + leftover check, always (unless KEEP_LAB=1)
# Probes: smoke test through HTTPS from outside the mesh (load balancer emulator -> Istio Gateway ->
# app), mTLS STRICT and the AuthorizationPolicy, Prometheus target and alert rules, Grafana dashboard,
# logs in Loki, Trivy reports of the app images, the HPA, a database backup + restore drill, Argo CD
# self-heal, and a chaos experiment with a hypothesis (one API pod killed, the service stays up).
# Environment: TX03V2_DIR (a tx03v2 checkout; default: clone at the pinned commit), TX03V2_REPO (the
# https URL to clone; default: the original tx03v2, set it to your fork, FORK.md), E2E_SKIP_BUILD=1,
# KEEP_LAB=1, LOCAL_KIND_INTERNAL=1 (inside a container that drives the host Docker daemon),
# E2E_DIAGNOSTICS_DIR (default ${TMPDIR:-/tmp}/dx03v2-harness/platform-diagnostics).
set -euo pipefail

# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
# shellcheck source=scripts/lib/k8s.sh
source "$REPO_ROOT/scripts/lib/k8s.sh"
export PATH="$REPO_ROOT/.tools/bin:$PATH"

NAMESPACE=dx03v2
HOST=dx03v2.tx03v2.local
TX03V2_REPO="${TX03V2_REPO:-https://github.com/maringelix/tx03v2.git}"
DIAG_DIR="${E2E_DIAGNOSTICS_DIR:-${TMPDIR:-/tmp}/dx03v2-harness/platform-diagnostics}"
CURL_IMAGE="curlimages/curl:8.22.0@sha256:58adaa4e8dca9c988bae2aba4ab3434a0bb2da16bbe3f92dec39ec7785166777"
WORK_DIR=""
TX=""
PASSED=0
GIT_SHA=""

pass() {
  PASSED=$((PASSED + 1))
  log "PASS $*"
}

lab() { bash "$TX/scripts/local-lab.sh" "$@"; }

cleanup() {
  local rc=$?
  if ((rc != 0)) && [[ -n "$TX" ]] && kubectl version >/dev/null 2>&1; then
    k8s_dump_diagnostics "$NAMESPACE" "$DIAG_DIR"
    kubectl -n argocd get application dx03v2 -o yaml >"$DIAG_DIR/argocd-application.yaml" 2>&1 || :
    kubectl get pods --all-namespaces -o wide >"$DIAG_DIR/all-pods.txt" 2>&1 || :
    log "diagnostics: $DIAG_DIR"
  fi
  if [[ -n "$TX" ]]; then
    if [[ "${KEEP_LAB:-0}" == 1 ]]; then
      log "KEEP_LAB=1: keeping the local lab (remove it with: bash $TX/scripts/local-lab.sh down)"
    elif ! lab down; then
      log "error: the local lab teardown failed"
      rc=1
    fi
  fi
  [[ -z "$WORK_DIR" ]] || rm -rf "$WORK_DIR"
  exit "$rc"
}

prepare_tx03v2() {
  local ref
  if [[ -n "${TX03V2_DIR:-}" ]]; then
    TX="$(cd "$TX03V2_DIR" && pwd)"
    log "using the tx03v2 checkout $TX ($(git -C "$TX" rev-parse --short HEAD))"
  else
    ref="$(tr -d '[:space:]' <"$REPO_ROOT/deploy/local/tx03v2.ref")"
    [[ "$ref" =~ ^[0-9a-f]{40}$ ]] || die "deploy/local/tx03v2.ref must hold a 40-character commit SHA"
    [[ "$TX03V2_REPO" =~ ^https://[A-Za-z0-9.-]+/[A-Za-z0-9._/-]+$ ]] || die "TX03V2_REPO must be an https git URL (got '$TX03V2_REPO')"
    TX="$WORK_DIR/tx03v2"
    git clone -q -- "$TX03V2_REPO" "$TX"
    git -C "$TX" checkout -q "$ref" || die "commit $ref of deploy/local/tx03v2.ref is not in $TX03V2_REPO (sync your fork or pin a commit of it)"
    log "tx03v2 cloned from $TX03V2_REPO at $ref"
  fi
  (cd "$TX" && bash scripts/install-tools.sh >/dev/null)
}

build_images() {
  local c
  if [[ "${E2E_SKIP_BUILD:-0}" == 1 ]]; then
    for c in dx03v2-api:e2e dx03v2-web:e2e; do
      docker image inspect "$c" >/dev/null 2>&1 || die "E2E_SKIP_BUILD=1 but the image $c does not exist"
    done
    return 0
  fi
  for c in api web; do
    log "building dx03v2-$c:e2e"
    docker build -q -f "$REPO_ROOT/$c/Dockerfile" --build-arg GIT_SHA="$GIT_SHA" -t "dx03v2-$c:e2e" "$REPO_ROOT" >/dev/null
  done
}

# run_pod NAMESPACE NAME MANIFEST -> creates a one-off pod, prints its log, returns 0 when it succeeded.
run_pod() {
  kubectl -n "$1" apply -f - >/dev/null <<<"$3"
  wait_pod "$1" "$2"
}

# wait_pod NAMESPACE NAME -> waits for a one-off pod to finish, prints its log and deletes it.
wait_pod() {
  local ns=$1 name=$2 phase=""
  for _ in $(seq 1 240); do
    phase="$(kubectl -n "$ns" get pod "$name" -o jsonpath='{.status.phase}' 2>/dev/null)" || phase=""
    [[ "$phase" == Succeeded || "$phase" == Failed ]] && break
    sleep 1
  done
  kubectl -n "$ns" logs "$name" 2>&1 || :
  kubectl -n "$ns" delete pod "$name" --wait=false >/dev/null 2>&1 || :
  [[ "$phase" == Succeeded ]]
}

# The probe namespace: outside the mesh and without NetworkPolicies, like a client on the internet.
probe_namespace() {
  kubectl apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: dx03v2-probe
  labels:
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/enforce-version: latest
EOF
  kubectl -n dx03v2-probe create configmap smoke --from-file=smoke.mjs="$REPO_ROOT/e2e/smoke.mjs" \
    --from-file=lib.mjs="$REPO_ROOT/e2e/lib.mjs" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  kubectl -n dx03v2-probe create configmap lab-ca --from-file=ca.crt=<(kubectl -n lab-system get configmap lab-ca -o jsonpath='{.data.ca\.crt}') \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
}

security_context() {
  cat <<'EOF'
  securityContext:
    runAsNonRoot: true
    runAsUser: 65532
    runAsGroup: 65532
    seccompProfile:
      type: RuntimeDefault
EOF
}

container_security() {
  cat <<'EOF'
      resources:
        requests:
          cpu: 20m
          memory: 64Mi
        limits:
          memory: 256Mi
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop: [ALL]
EOF
}

gateway_ip() {
  kubectl -n "$NAMESPACE" get gateway dx03v2 -o jsonpath='{.status.addresses[0].value}'
}

# Smoke test from outside the mesh: HTTPS to dx03v2.tx03v2.local through the load balancer emulator,
# verified against the lab CA, run by Node.js of the API image.
check_smoke() {
  local ip token api_image out
  ip="$(gateway_ip)"
  token="$(kubectl -n lab-secrets get secret tx03v2-lab-app-admin-token -o jsonpath='{.data.token}' | base64 -d)"
  api_image="$(kubectl -n "$NAMESPACE" get deployment api -o jsonpath='{.spec.template.spec.containers[0].image}')"
  kubectl -n dx03v2-probe create secret generic smoke-token --from-literal=ADMIN_TOKEN="$token" --dry-run=client -o yaml |
    kubectl apply -f - >/dev/null
  out="$(run_pod dx03v2-probe smoke "$(
    cat <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: smoke
spec:
  restartPolicy: Never
  automountServiceAccountToken: false
  hostAliases:
    - ip: "$ip"
      hostnames: ["$HOST"]
$(security_context)
  containers:
    - name: smoke
      image: $api_image
      args: ["/smoke/smoke.mjs"]
      env:
        - name: BASE_URL
          value: https://$HOST
        - name: SMOKE_WAIT_SECONDS
          value: "60"
        # /api straight to the API (its own CSP, like the GKE Gateway) and an external X-Request-Id kept (the
        # EnvoyFilter gateway-preserve-request-id of tx03v2, like nginx): e2e/smoke.mjs mode istio.
        - name: SMOKE_EDGE
          value: istio
        - name: NODE_EXTRA_CA_CERTS
          value: /lab-ca/ca.crt
        - name: ADMIN_TOKEN
          valueFrom:
            secretKeyRef:
              name: smoke-token
              key: ADMIN_TOKEN
      volumeMounts:
        - name: smoke
          mountPath: /smoke
        - name: lab-ca
          mountPath: /lab-ca
$(container_security)
  volumes:
    - name: smoke
      configMap:
        name: smoke
    - name: lab-ca
      configMap:
        name: lab-ca
EOF
  )")" || {
    printf '%s\n' "$out" >&2
    die "smoke test through the Gateway failed"
  }
  pass "smoke through https://$HOST (load balancer $ip -> Istio Gateway -> app): $(sed -n 's/^smoke: //p' <<<"$out" | tail -n 1)"
}

# yaml_args ARG... -> a YAML block list of single-quoted strings (safe for quotes and braces).
yaml_args() {
  local a
  for a in "$@"; do
    printf "        - '%s'\n" "${a//\'/\'\'}"
  done
}

# curl_probe URL [CURL ARGS...] -> response body, then the HTTP code on the last line (000 when the
# connection is refused), of a curl pod in dx03v2-probe (outside the mesh). The lab CA is at
# /lab-ca/ca.crt.
curl_probe() {
  local url=$1 name
  shift
  name="curl-$RANDOM"
  run_pod dx03v2-probe "$name" "$(
    cat <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: $name
spec:
  restartPolicy: Never
  automountServiceAccountToken: false
$(security_context)
  containers:
    - name: curl
      image: $CURL_IMAGE
      args:
$(yaml_args -sS -m 10 -w '\n%{http_code}' "$@" "$url")
      volumeMounts:
        - name: lab-ca
          mountPath: /lab-ca
$(container_security)
  volumes:
    - name: lab-ca
      configMap:
        name: lab-ca
EOF
  )" 2>/dev/null || :
}

check_mesh() {
  local code
  code="$(curl_probe "http://api.$NAMESPACE.svc:3000/readyz" | tail -n 1)"
  [[ "$code" == 000 ]] || die "mesh: a plaintext client outside the mesh reached api:3000 (HTTP $code)"
  pass "mesh: plaintext client outside the mesh -> api:3000 refused (STRICT mTLS + NetworkPolicy)"
}

prom_query() {
  curl_probe "http://kube-prometheus-stack-prometheus.monitoring.svc:9090/api/v1/$1" -G --data-urlencode "$2"
}

check_observability() {
  local body user pass
  for _ in $(seq 1 40); do
    body="$(prom_query query 'query=up{namespace="dx03v2",service="api"}')"
    [[ "$body" == *'"value":['*',"1"]'* ]] && break
    sleep 6
  done
  [[ "$body" == *'"value":['*',"1"]'* ]] || die "observability: Prometheus has no healthy target of the dx03v2 API"
  pass "observability: Prometheus scrapes the API through the mesh (up == 1)"
  # The operator turns the PrometheusRule into a rule file and Prometheus reloads it on its own
  # schedule (the CI of dx01v2 got here before the reload once).
  local rules=(Dx03v2ApiDown Dx03v2HighErrorRate Dx03v2HighLatencyP95 Dx03v2PodRestarting Dx03v2PodNotReady) missing
  for _ in $(seq 1 20); do
    body="$(prom_query rules 'type=alert')"
    missing=""
    for rule in "${rules[@]}"; do
      [[ "$body" == *"\"$rule\""* ]] || missing+=" $rule"
    done
    [[ -z "$missing" ]] && break
    sleep 6
  done
  [[ -z "$missing" ]] || die "observability: alert rules not loaded by Prometheus:$missing"
  pass "observability: the five dx03v2 alert rules are loaded"
  # The smoke traffic shows up after the next scrapes (the CI of dx01v2 got here before them once).
  for _ in $(seq 1 20); do
    body="$(prom_query query 'query=sum(rate(http_request_duration_seconds_count{namespace="dx03v2",route="/api/messages"}[5m]))')"
    [[ "$body" == *'"result":[{'* ]] && break
    sleep 6
  done
  [[ "$body" == *'"result":[{'* ]] || die "observability: no request metrics of /api/messages"
  pass "observability: request metrics of the smoke traffic are in Prometheus"
  user="$(kubectl -n monitoring get secret grafana-admin -o jsonpath='{.data.admin-user}' | base64 -d)"
  pass="$(kubectl -n monitoring get secret grafana-admin -o jsonpath='{.data.admin-password}' | base64 -d)"
  # The Grafana sidecar loads the dashboard ConfigMap on its own schedule.
  for _ in $(seq 1 20); do
    body="$(curl_probe "http://kube-prometheus-stack-grafana.monitoring.svc/api/dashboards/uid/dx03v2-app" -u "$user:$pass")"
    [[ "$(tail -n 1 <<<"$body")" == 200 ]] && break
    sleep 6
  done
  [[ "$(tail -n 1 <<<"$body")" == 200 ]] || die "observability: Grafana does not serve the dx03v2 dashboard"
  pass "observability: Grafana loaded the dx03v2 dashboard from its ConfigMap"
  for _ in $(seq 1 30); do
    body="$(curl_probe 'http://loki.monitoring.svc:3100/loki/api/v1/query' -G --data-urlencode 'query=count_over_time({namespace="dx03v2",app="api"}[15m])')"
    [[ "$body" == *'"result":[{'* ]] && break
    sleep 6
  done
  [[ "$body" == *'"result":[{'* ]] || die "observability: no API logs in Loki"
  pass "observability: API logs are in Loki"
}

check_trivy() {
  local n
  for _ in $(seq 1 120); do
    n="$(kubectl -n "$NAMESPACE" get vulnerabilityreports -o name 2>/dev/null | awk '/replicaset-(api|web)-/ { n++ } END { print n + 0 }')" || n=0
    ((n >= 3)) && break
    sleep 5
  done
  ((n >= 3)) || die "trivy: expected VulnerabilityReports for api (api, migrate) and web, found $n"
  pass "trivy: VulnerabilityReports of the app images ($(kubectl -n "$NAMESPACE" get vulnerabilityreports -o jsonpath='{range .items[*]}{.metadata.labels.trivy-operator\.container\.name}={.report.summary.criticalCount}/{.report.summary.highCount} {end}') critical/high, unfixed ignored)"
}

check_hpa() {
  local active
  for _ in $(seq 1 60); do
    active="$(kubectl -n "$NAMESPACE" get hpa api -o jsonpath='{.status.conditions[?(@.type=="ScalingActive")].status}' 2>/dev/null)" || active=""
    [[ "$active" == True ]] && break
    sleep 5
  done
  [[ "$active" == True ]] || die "hpa: the HPA of the API never became ScalingActive (metrics-server)"
  pass "hpa: api HPA ScalingActive with $(kubectl -n "$NAMESPACE" get hpa api -o jsonpath='{.status.currentReplicas}') replicas (2-4)"
}

api() { # METHOD PATH [BODY] -> curl through the Gateway (HTTPS, lab CA) from the probe namespace
  local ip
  local -a extra=()
  ip="$(gateway_ip)"
  [[ -z "${3:-}" ]] || extra+=(-H 'content-type: application/json' -d "$3")
  [[ -z "${ADMIN:-}" ]] || extra+=(-H "authorization: Bearer $ADMIN")
  curl_probe "https://$HOST$2" --cacert /lab-ca/ca.crt --resolve "$HOST:443:$ip" -X "$1" "${extra[@]}"
}

# Database backup and restore drill: dump the database of the lab, delete a message, restore the dump,
# and the message is back (the restore of v1 was never rehearsed).
check_db_backup() {
  local db_container=tx03v2-local-db marker body id
  marker="backup-drill-$RANDOM"
  body="$(api POST /api/messages "{\"author\":\"drill\",\"text\":\"$marker\"}")"
  id="$(sed -nE 's/.*"id":"?([0-9a-f-]+)"?.*/\1/p' <<<"$body" | head -n 1)"
  [[ -n "$id" ]] || die "backup: could not create the marker message ($body)"
  docker exec "$db_container" pg_dump -U dx03v2 -d dx03v2 --clean --if-exists >"$WORK_DIR/dx03v2.sql"
  [[ -s "$WORK_DIR/dx03v2.sql" ]] || die "backup: empty dump"
  ADMIN="$(kubectl -n lab-secrets get secret tx03v2-lab-app-admin-token -o jsonpath='{.data.token}' | base64 -d)" \
    api DELETE "/api/messages/$id" >/dev/null
  [[ "$(api GET /api/messages?limit=100)" != *"$marker"* ]] || die "backup: the marker was not deleted"
  docker exec -i "$db_container" psql -q -U dx03v2 -d dx03v2 -v ON_ERROR_STOP=1 <"$WORK_DIR/dx03v2.sql" >/dev/null
  [[ "$(api GET /api/messages?limit=100)" == *"$marker"* ]] || die "backup: the restored database does not have the marker"
  pass "backup: pg_dump of the lab database, marker deleted, restore brings it back ($(wc -c <"$WORK_DIR/dx03v2.sql") bytes)"
}

check_self_heal() {
  kubectl -n "$NAMESPACE" delete networkpolicy web-egress-mesh --wait=true >/dev/null
  for _ in $(seq 1 40); do
    kubectl -n "$NAMESPACE" get networkpolicy web-egress-mesh >/dev/null 2>&1 && {
      pass "gitops: Argo CD recreated a deleted NetworkPolicy (self-heal)"
      return 0
    }
    sleep 3
  done
  die "gitops: Argo CD did not recreate the deleted NetworkPolicy web-egress-mesh"
}

# Hypothesis: with 2 API replicas behind the Gateway, killing one API pod does not interrupt reads
# (at least 38 of 40 requests over 20 s succeed).
check_chaos() {
  local ip out ok name=chaos-reader
  ip="$(gateway_ip)"
  kubectl -n dx03v2-probe apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: $name
spec:
  restartPolicy: Never
  automountServiceAccountToken: false
$(security_context)
  containers:
    - name: curl
      image: $CURL_IMAGE
      command: ["sh", "-c"]
      args:
        - |
          sleep 5; ok=0
          for i in \$(seq 1 40); do
            curl -s --cacert /lab-ca/ca.crt -m 2 -o /dev/null -w '%{http_code}' --resolve "$HOST:443:$ip" "https://$HOST/api/messages?limit=1" | grep -q 200 && ok=\$((ok + 1))
            sleep 0.5
          done
          echo "ok=\$ok"
      volumeMounts:
        - name: lab-ca
          mountPath: /lab-ca
$(container_security)
  volumes:
    - name: lab-ca
      configMap:
        name: lab-ca
EOF
  sleep 8
  kubectl -n "$NAMESPACE" apply -f - >/dev/null <<EOF
apiVersion: chaos-mesh.org/v1alpha1
kind: PodChaos
metadata:
  name: kill-one-api
spec:
  action: pod-kill
  mode: one
  selector:
    namespaces: [$NAMESPACE]
    labelSelectors:
      app.kubernetes.io/name: api
EOF
  out="$(wait_pod dx03v2-probe "$name")" || :
  kubectl -n "$NAMESPACE" delete podchaos kill-one-api >/dev/null 2>&1 || :
  ok="$(sed -n 's/^ok=//p' <<<"$out")"
  if [[ ! "$ok" =~ ^[0-9]+$ ]] || ((ok < 38)); then
    die "chaos: hypothesis refuted, ${ok:-?}/40 reads succeeded while one API pod was killed"
  fi
  pass "chaos: one API pod killed by Chaos Mesh, $ok/40 reads through the Gateway succeeded (hypothesis held)"
}

main() {
  require_cmd git docker kubectl node ssh base64
  WORK_DIR="$(mktemp -d)"
  trap cleanup EXIT
  GIT_SHA="$(git -C "$REPO_ROOT" rev-parse --verify -q HEAD || printf '%040d' 0)"
  prepare_tx03v2
  build_images
  lab up
  KUBECONFIG="$(lab kubeconfig | tail -n 1)"
  export KUBECONFIG
  GIT_SHA="$GIT_SHA" DEPLOY_ALLOW_DIRTY=1 bash "$REPO_ROOT/scripts/deploy-local.sh"
  pass "gitops: deploy-local pushed the images and the manifests; Argo CD synced dx03v2 (Synced, Healthy)"
  probe_namespace
  # The drill writes twice; the smoke test then uses up the write budget of the shared client address.
  check_db_backup
  check_smoke
  check_mesh
  check_observability
  check_trivy
  check_hpa
  check_self_heal
  check_chaos
  printf 'SUMMARY: dx03v2 on the tx03v2 local platform: %d probes passed\n' "$PASSED"
}

main "$@"
