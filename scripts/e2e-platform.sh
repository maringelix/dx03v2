#!/usr/bin/env bash
# The app on the full local platform of tx03v2 (harness stage platform, CI job e2e-platform). Steps:
#   1. tx03v2 at the pinned commit (deploy/local/tx03v2.ref) or TX03V2_DIR: scripts/local-lab.sh up
#   2. build dx03v2-api:e2e / dx03v2-web:e2e (skipped with E2E_SKIP_BUILD=1)
#   3. scripts/deploy-local.sh: registry, GitOps repository, Argo CD sync
#   4. probes of the app on the platform (below), every one with real traffic or API calls
#   5. tx03v2 scripts/local-lab.sh down + leftover check, always (unless KEEP_LAB=1)
# Probes: smoke test through HTTPS from outside the mesh (load balancer emulator -> Istio Gateway ->
# app), mTLS STRICT and the AuthorizationPolicy, L7 canary/retry/outlier behavior, Prometheus target and alert rules, Grafana dashboard,
# logs in Loki, one OpenTelemetry trace from the edge to the database (logs and exemplars carrying its
# id), Trivy reports of the app images, the HPA, a zero-downtime GitOps rollout of a new version, a
# database backup + restore drill, Argo CD self-heal, and two chaos experiments with a hypothesis (one
# API pod killed; 200 ms between the API and PostgreSQL, visible in the trace).
# Environment: TX03V2_DIR (a tx03v2 checkout; default: clone at the pinned commit), TX03V2_REPO (the
# https URL to clone; default: the original tx03v2, set it to your fork, FORK.md), E2E_SKIP_BUILD=1,
# KEEP_LAB=1, LOCAL_KIND_INTERNAL=1 (inside a container that drives the host Docker daemon),
# LOCAL_SIZE=small (the size of the tx03v2 platform for 7 GB of Docker memory, proved in the CI by
# scripts/e2e-platform-small.sh; docs/LAB_LOCAL.md), E2E_DIAGNOSTICS_DIR (default
# ${TMPDIR:-/tmp}/dx03v2-harness/platform-diagnostics), LOCAL_STATE_DIR (the state of the lab this
# script creates; default ${XDG_STATE_HOME:-$HOME/.local/state}/dx03v2-platform-local, not the one of
# `make local-up` in tx03v2: a lab you keep there is never adopted and destroyed by this run).
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
LAB_KUBECONFIG=""
TX=""
PASSED=0
GIT_SHA=""
PREVIOUS_SHA=""

pass() {
  PASSED=$((PASSED + 1))
  log "PASS $*"
}

lab() { bash "$TX/scripts/local-lab.sh" "$@"; }

cleanup() {
  local rc=$?
  # Diagnostics only through the kubeconfig of the lab (set once it exists): the current context of
  # the machine is never read, and no cluster of yours ends up in a public artifact.
  if ((rc != 0)) && [[ -n "$LAB_KUBECONFIG" ]] && kubectl version >/dev/null 2>&1; then
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
  local c previous_tree
  PREVIOUS_SHA="$(git -C "$REPO_ROOT" rev-parse --verify "$GIT_SHA^")" ||
    die "the platform release exercise needs the previous source commit"
  if [[ "${E2E_SKIP_BUILD:-0}" == 1 ]]; then
    for c in dx03v2-api:e2e dx03v2-web:e2e; do
      docker image inspect "$c" >/dev/null 2>&1 || die "E2E_SKIP_BUILD=1 but the image $c does not exist"
    done
  else
    for c in api web; do
      log "building dx03v2-$c:e2e"
      docker build -q -f "$REPO_ROOT/$c/Dockerfile" --build-arg GIT_SHA="$GIT_SHA" \
        --build-arg SOURCE_REPOSITORY="${GITHUB_REPOSITORY:-maringelix/dx03v2}" \
        -t "dx03v2-$c:e2e" "$REPO_ROOT" >/dev/null
    done
  fi
  previous_tree="$WORK_DIR/previous-source"
  mkdir -p "$previous_tree"
  git -C "$REPO_ROOT" archive "$PREVIOUS_SHA" | tar -x -C "$previous_tree"
  # The first deploy of the exercise runs the previous release with the manifests under test, and the backends
  # and probes of the service-mesh exercise are programs of the API image (api/src/mesh-demo.ts, mesh-probe.ts).
  # The commit that introduces them has no previous release that contains them, so the previous image gets those
  # two sources from the tree under test; once the previous commit has them, nothing is copied.
  for c in api/src/mesh-demo.ts api/src/mesh-probe.ts; do
    [[ -e "$previous_tree/$c" ]] || cp "$REPO_ROOT/$c" "$previous_tree/$c"
  done
  for c in api web; do
    log "building previous release dx03v2-$c:previous ($PREVIOUS_SHA)"
    docker build -q -f "$previous_tree/$c/Dockerfile" --build-arg GIT_SHA="$PREVIOUS_SHA" \
      --build-arg SOURCE_REPOSITORY="${GITHUB_REPOSITORY:-maringelix/dx03v2}" \
      -t "dx03v2-$c:previous" "$previous_tree" >/dev/null
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
        # /api routes straight to the API (its own CSP) and the Gateway preserves the request ID.
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

run_mesh_probe() {
  local job=$1 service_account=$2 mode=$3 app_label=$4 image
  image="$(kubectl -n "$NAMESPACE" get deployment mesh-stable -o jsonpath='{.spec.template.spec.containers[?(@.name=="main")].image}')"
  [[ "$image" =~ ^[^[:space:]]+(@sha256:[0-9a-f]{64}|:[A-Za-z0-9._-]+)$ ]] ||
    die "mesh: the probe image is not the API image selected by GitOps"
  kubectl -n "$NAMESPACE" delete job "$job" --ignore-not-found=true --wait=true >/dev/null
  kubectl -n "$NAMESPACE" apply -f - >/dev/null <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: $job
spec:
  activeDeadlineSeconds: 120
  backoffLimit: 0
  ttlSecondsAfterFinished: 300
  template:
    metadata:
      labels:
        app.kubernetes.io/name: $app_label
    spec:
      serviceAccountName: $service_account
      automountServiceAccountToken: false
      restartPolicy: Never
      securityContext:
        runAsNonRoot: true
        runAsUser: 65532
        runAsGroup: 65532
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: probe
          image: "$image"
          imagePullPolicy: IfNotPresent
          args: ["dist/mesh-probe.js"]
          env:
            - name: MESH_PROBE_MODE
              value: "$mode"
            - name: MESH_PROBE_TARGET
              value: http://mesh-demo:3000
          # The Gatekeeper constraint required-probes asks every container of the namespace for a readiness
          # probe, also the one-shot client of the exercise: this one only proves that the runtime answers.
          readinessProbe:
            exec:
              command: ["/nodejs/bin/node", "-e", "process.exit(0)"]
            periodSeconds: 5
            timeoutSeconds: 5
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            runAsNonRoot: true
            capabilities:
              drop: ["ALL"]
          resources:
            requests:
              cpu: 25m
              memory: 64Mi
            limits:
              memory: 128Mi
EOF
  if ! kubectl -n "$NAMESPACE" wait --for=condition=complete "job/$job" --timeout=150s; then
    if ! kubectl -n "$NAMESPACE" logs "job/$job"; then
      log "mesh: no logs were available for failed probe job $job"
    fi
    die "mesh: probe job $job did not complete successfully"
  fi
  kubectl -n "$NAMESPACE" logs "job/$job"
}

check_mesh_advanced() {
  local code allowed_log intruder_log canary_logs retry_id isolation_id retry_count=0 isolation_count=0 line
  code="$(curl_probe "http://mesh-demo.$NAMESPACE.svc:3000/variant" | tail -n 1)"
  [[ "$code" == 000 ]] || die "mesh: an external, non-mesh client reached the full-profile demo (HTTP $code)"
  pass "mesh: the canary service is not exposed outside the ambient mesh"

  allowed_log="$(run_mesh_probe mesh-probe mesh-probe allowed mesh-probe)"
  [[ "$allowed_log" == *MESH_PROBE_RESULT\ total=400* ]] || die "mesh: the authorized probe did not report its traffic sample"
  [[ "$allowed_log" =~ retry_request_id=([A-Za-z0-9_]+)[[:space:]]isolation_request_id=([A-Za-z0-9_]+) ]] ||
    die "mesh: the authorized probe did not report retry identifiers"
  retry_id="${BASH_REMATCH[1]}"
  isolation_id="${BASH_REMATCH[2]}"
  canary_logs="$(kubectl -n "$NAMESPACE" logs -l mesh.lab/variant=canary -c main --since=10m)"
  while IFS= read -r line; do
    if [[ "$line" == *"probe_id=$retry_id"* ]]; then retry_count=$((retry_count + 1)); fi
    if [[ "$line" == *"probe_id=$isolation_id"* ]]; then isolation_count=$((isolation_count + 1)); fi
  done <<<"$canary_logs"
  [[ "$retry_count" -eq 3 ]] || die "mesh: retry amplification was $retry_count attempts; expected the original plus two retries"
  [[ "$isolation_count" -eq 0 ]] || die "mesh: the ejected canary received another request ($isolation_count backend attempts)"
  pass "mesh: HTTPRoute balances the 80/20 canary, caps retries at two, and ejects the failing endpoint"

  intruder_log="$(run_mesh_probe mesh-intruder mesh-intruder intruder mesh-intruder)"
  [[ "$intruder_log" == *MESH_PROBE_DENIED\ status=403* ]] || die "mesh: an unauthorized SPIFFE identity was not denied by the waypoint"
  pass "mesh: waypoint AuthorizationPolicy rejects the intruder identity with HTTP 403"
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
  # schedule (the CI got here before the reload once).
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
  # The smoke traffic shows up after the next scrapes (the CI got here before them once).
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

# hex BYTES -> random lowercase hex (W3C trace and span ids, fake commit SHAs).
hex() { od -An -N"$1" -tx1 /dev/urandom | tr -d ' \n'; }

# tempo_trace TRACE_ID -> the trace as Tempo returns it (OTLP JSON), polled for up to 2 minutes.
tempo_trace() {
  local body
  for _ in $(seq 1 40); do
    body="$(curl_probe "http://tempo.monitoring.svc:3200/api/traces/$1")"
    if [[ "$(tail -n 1 <<<"$body")" == 200 && "$body" == *'"spanId"'* ]]; then
      sed '$d' <<<"$body"
      return 0
    fi
    sleep 3
  done
  return 1
}

# spans_of < OTLP JSON -> one line per span: <service.name> TAB <span name> TAB <duration in ms>.
spans_of() {
  # shellcheck disable=SC2016 # JavaScript template literals, not shell expansions
  node -e 'const d = JSON.parse(require("fs").readFileSync(0, "utf8"));
    for (const b of d.batches ?? d.resourceSpans ?? []) {
      const svc = (b.resource?.attributes ?? []).find((a) => a.key === "service.name")?.value?.stringValue ?? "?";
      for (const s of (b.scopeSpans ?? []).flatMap((x) => x.spans ?? [])) {
        const ms = Number(BigInt(s.endTimeUnixNano) - BigInt(s.startTimeUnixNano)) / 1e6;
        console.log(`${svc}\t${s.name}\t${Math.round(ms)}`);
      }
    }'
}

# traced_read TRACE_ID -> HTTP code of GET /api/messages?limit=1 through the Gateway, as part of the
# trace TRACE_ID (W3C traceparent with a random parent span).
traced_read() {
  local ip
  ip="$(gateway_ip)"
  curl_probe "https://$HOST/api/messages?limit=1" --cacert /lab-ca/ca.crt --resolve "$HOST:443:$ip" \
    -H "traceparent: 00-$1-$(hex 8)-01" | tail -n 1
}

# trace_spans TRACE_ID -> the span lines of the trace once the Gateway span, the API span and its
# query span are all in Tempo (the Collector and the API export in batches); fails after 2 minutes.
trace_spans() {
  local body spans
  for _ in $(seq 1 20); do
    body="$(tempo_trace "$1")" || return 1
    spans="$(spans_of <<<"$body")"
    if awk -F'\t' '$1 == "dx03v2-istio.dx03v2" { g = 1 } $1 == "dx03v2-api" && $2 == "GET /api/messages" { a = 1 }
      $1 == "dx03v2-api" && $2 == "SELECT dx03v2" { q = 1 } END { exit !(g && a && q) }' <<<"$spans"; then
      printf '%s\n' "$spans"
      return 0
    fi
    sleep 6
  done
  printf '%s\n' "$spans" >&2
  return 1
}

# Observability 2.0 for the app: one trace from the edge to the database, and the three signals linked
# (the log lines of the request and an exemplar of its latency histogram carry the trace id).
check_tracing() {
  local trace code body start
  trace="$(hex 16)"
  code="$(traced_read "$trace")"
  [[ "$code" == 200 ]] || die "tracing: the traced read failed (HTTP $code)"
  trace_spans "$trace" >/dev/null ||
    die "tracing: trace $trace in Tempo lacks the Gateway, the API or the query span (above)"
  pass "tracing: one trace in Tempo from the edge to the database (Gateway -> GET /api/messages -> SELECT dx03v2)"
  for _ in $(seq 1 30); do
    body="$(curl_probe 'http://loki.monitoring.svc:3100/loki/api/v1/query_range' -G \
      --data-urlencode "query={namespace=\"$NAMESPACE\",app=\"api\"} |= \"$trace\"" --data-urlencode since=15m)"
    [[ "$body" == *'"values":[['* ]] && break
    sleep 5
  done
  [[ "$body" == *'"values":[['* ]] || die "tracing: no API log line with the trace id $trace in Loki"
  pass "tracing: the API log lines of the request carry its trace id in Loki (logs -> traces)"
  start=$(($(date +%s) - 900))
  for _ in $(seq 1 25); do
    body="$(curl_probe 'http://kube-prometheus-stack-prometheus.monitoring.svc:9090/api/v1/query_exemplars' -G \
      --data-urlencode "query=http_request_duration_seconds_bucket{namespace=\"$NAMESPACE\",route=\"/api/messages\"}" \
      --data-urlencode "start=$start" --data-urlencode "end=$(($(date +%s) + 60))")"
    [[ "$body" == *"$trace"* ]] && break
    sleep 6
  done
  [[ "$body" == *"$trace"* ]] || die "tracing: Prometheus has no exemplar of the API histogram with the trace id $trace"
  pass "tracing: the latency histogram of the API keeps the trace id as an exemplar (metrics -> traces)"
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

# Hypothesis: a new version delivered the GitOps way (new image tags in the GitOps repository, Argo CD
# sync, RollingUpdate with maxUnavailable 0, readiness probes, preStop sleep and graceful shutdown)
# loses no request: a reader that alternates API and web requests through the Gateway sees no error.
check_zero_downtime() {
  local ip name=rollout-reader phase="" out total fail info
  ip="$(gateway_ip)"
  info="$(api GET /api/info)"
  [[ "$info" == *"$PREVIOUS_SHA"* ]] || die "rollout: the starting API is not the previous release ($PREVIOUS_SHA)"
  [[ "$(docker image inspect dx03v2-api:previous --format '{{.Id}}')" != \
    "$(docker image inspect dx03v2-api:e2e --format '{{.Id}}')" ]] ||
    die "rollout: old and new API images are not distinct content"
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
          for i in \$(seq 1 1500); do
            for path in /api/messages?limit=1 /; do
              code=\$(curl -s --cacert /lab-ca/ca.crt -m 3 -o /dev/null -w '%{http_code}' --resolve "$HOST:443:$ip" "https://$HOST\$path")
              if [ "\$code" = 200 ]; then echo ok; else echo "fail \$code \$path"; fi
            done
            sleep 0.2
          done
      volumeMounts:
        - name: lab-ca
          mountPath: /lab-ca
$(container_security)
  volumes:
    - name: lab-ca
      configMap:
        name: lab-ca
EOF
  kubectl -n dx03v2-probe wait --for=condition=Ready "pod/$name" --timeout=120s >/dev/null ||
    die "rollout: the reader pod did not start"
  sleep 5
  GIT_SHA="$GIT_SHA" DEPLOY_IMAGES="dx03v2-api:e2e dx03v2-web:e2e" DEPLOY_ALLOW_DIRTY=1 \
    bash "$REPO_ROOT/scripts/deploy-local.sh" >"$WORK_DIR/rollout.log" 2>&1 || {
    cat "$WORK_DIR/rollout.log" >&2
    die "rollout: deploy-local of the new version failed"
  }
  for deploy in api web; do
    [[ "$(kubectl -n "$NAMESPACE" get deployment "$deploy" -o jsonpath='{.spec.template.spec.containers[0].image}')" == *":$GIT_SHA" ]] ||
      die "rollout: the $deploy Deployment does not run the new tag $GIT_SHA"
  done
  info="$(api GET /api/info)"
  [[ "$info" == *"$GIT_SHA"* ]] || die "rollout: the new API content does not report source commit $GIT_SHA"
  # A few more seconds of traffic once the old pods are gone.
  sleep 10
  phase="$(kubectl -n dx03v2-probe get pod "$name" -o jsonpath='{.status.phase}')"
  [[ "$phase" == Running ]] || die "rollout: the reader stopped before the rollout ended (phase $phase): widen its window"
  out="$(kubectl -n dx03v2-probe logs "$name")"
  kubectl -n dx03v2-probe delete pod "$name" --wait=false >/dev/null 2>&1 || :
  total="$(grep -cE '^(ok|fail)' <<<"$out" || :)"
  fail="$(grep -c '^fail' <<<"$out" || :)"
  ((total >= 100)) || die "rollout: the reader made only $total requests"
  ((fail == 0)) ||
    die "rollout: hypothesis refuted, $fail of $total requests failed during the rollout: $(grep '^fail' <<<"$out" | sort | uniq -c | tr '\n' ' ')"
  pass "rollout: API/Web content moved from $PREVIOUS_SHA to $GIT_SHA via GitOps with 0 of $total requests lost"
}

# A not-ready candidate must leave the last ready version available; publishing the previous image
# to the GitOps branch rolls the application back without changing database contents.
check_failed_rollout_and_rollback() {
  local current_info previous_info bad_image waiting available ip name=rollback-reader out fail marker body
  current_info="$(api GET /api/info)"
  [[ "$current_info" == *"$GIT_SHA"* ]] || die "rollback: the current release is not serving before the failure exercise"
  marker="rollback-keeps-data-$RANDOM"
  body="$(api POST /api/messages "{\"author\":\"rollback-drill\",\"text\":\"$marker\"}")"
  [[ "$body" == *"$marker"* ]] || die "rollback: could not create the data-preservation marker"
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
          for i in \$(seq 1 1800); do
            response=\$(curl -sS --cacert /lab-ca/ca.crt -m 3 -w '\\n%{http_code}' --resolve "$HOST:443:$ip" "https://$HOST/api/info")
            code=\$(printf '%s\\n' "\$response" | tail -n 1)
            body=\$(printf '%s\\n' "\$response" | sed '\$d')
            if [ "\$code" = 200 ]; then
              if printf '%s' "\$body" | grep -qF "$PREVIOUS_SHA"; then echo rollback-seen; break; fi
              echo ok
            else
              echo "fail \$code"
            fi
            sleep 0.5
          done
      volumeMounts:
        - name: lab-ca
          mountPath: /lab-ca
$(container_security)
  volumes:
    - name: lab-ca
      configMap:
        name: lab-ca
EOF
  kubectl -n dx03v2-probe wait --for=condition=Ready "pod/$name" --timeout=120s >/dev/null ||
    die "rollback: the availability reader did not start"
  kubectl -n argocd patch application dx03v2 --type=json \
    -p='[{"op":"remove","path":"/spec/syncPolicy/automated"}]' >/dev/null ||
    die "rollback: could not pause automated sync for the failure injection"
  bad_image="$(kubectl -n lab-system get configmap lab-contract -o jsonpath='{.data.registry}')/dx03v2/api:missing-$RANDOM"
  kubectl -n "$NAMESPACE" patch deployment api --type=strategic \
    -p "{\"spec\":{\"template\":{\"spec\":{\"containers\":[{\"name\":\"api\",\"image\":\"$bad_image\"}]}}}}" >/dev/null
  waiting=""
  for _ in $(seq 1 90); do
    waiting="$(kubectl -n "$NAMESPACE" get pods -l app.kubernetes.io/name=api -o json |
      jq -r --arg image "$bad_image" '
        [.items[]
         | select(any(.spec.containers[]?; .image == $image))
         | .status.containerStatuses[]?
         | select(.ready == false and (.state.waiting.reason == "ErrImagePull" or .state.waiting.reason == "ImagePullBackOff"))]
        | length
      ')" || waiting=""
    [[ "$waiting" =~ ^[0-9]+$ ]] && ((waiting >= 1)) && break
    sleep 2
  done
  if ! [[ "$waiting" =~ ^[0-9]+$ ]] || ((waiting < 1)); then
    die "rollback: the deliberately unavailable API image did not fail readiness"
  fi
  available="$(kubectl -n "$NAMESPACE" get deployment api -o jsonpath='{.status.availableReplicas}')"
  available="${available:-0}"
  ((available >= 2)) || die "rollback: only $available ready API replicas remained during the failed rollout"
  [[ "$(api GET /api/info)" == *"$GIT_SHA"* ]] ||
    die "rollback: the last ready API version stopped serving during the failed rollout"

  GIT_SHA="$PREVIOUS_SHA" DEPLOY_IMAGES="dx03v2-api:previous dx03v2-web:previous" DEPLOY_ALLOW_DIRTY=1 \
    bash "$REPO_ROOT/scripts/deploy-local.sh" >"$WORK_DIR/rollback.log" 2>&1 || {
      cat "$WORK_DIR/rollback.log" >&2
      die "rollback: GitOps promotion of the previous release failed"
    }
  previous_info="$(api GET /api/info)"
  [[ "$previous_info" == *"$PREVIOUS_SHA"* ]] ||
    die "rollback: the previous API content was not restored after the failed rollout"
  [[ "$(api GET /api/messages?limit=100)" == *"$marker"* ]] ||
    die "rollback: application rollback lost the message written before the failed release"
  [[ "$(docker exec tx03v2-local-db psql -At -U dx03v2 -d dx03v2 -c "SELECT 1 FROM information_schema.columns WHERE table_name='messages' AND column_name='display_name'")" == 1 ]] ||
    die "rollback: the additive database migration was incorrectly rolled back with the application"
  out="$(kubectl -n dx03v2-probe logs "$name")"
  kubectl -n dx03v2-probe delete pod "$name" --wait=false >/dev/null 2>&1 || :
  fail="$(grep -c '^fail' <<<"$out" || :)"
  grep -q '^rollback-seen$' <<<"$out" ||
    die "rollback: the availability reader did not observe the previous version serving again"
  ((fail == 0)) || die "rollback: the reader saw $fail failed requests while a not-ready image was rejected and GitOps restored the previous release"
  pass "rollback: unready API candidate rejected; two previous replicas stayed ready; GitOps restored the previous image $PREVIOUS_SHA with no failed probe requests"
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

# Hypothesis: 200 ms of network latency between the API and PostgreSQL (NetworkChaos on the API pods,
# target: the database address of the contract) slows reads but fails none (the query timeouts are 5-6 s),
# and the trace shows the delay where it happens, in the query span.
check_chaos_db_latency() {
  local db_ip code ok=0 trace spans ms
  db_ip="$(kubectl -n lab-system get configmap lab-contract -o jsonpath='{.data.db\.endpoint-ip}')"
  kubectl -n "$NAMESPACE" apply -f - >/dev/null <<EOF
apiVersion: chaos-mesh.org/v1alpha1
kind: NetworkChaos
metadata:
  name: delay-api-to-db
spec:
  action: delay
  mode: all
  selector:
    namespaces: [$NAMESPACE]
    labelSelectors:
      app.kubernetes.io/name: api
  delay:
    latency: 200ms
    jitter: 0ms
    correlation: "0"
  direction: to
  externalTargets: ["$db_ip"]
  duration: 180s
EOF
  for _ in $(seq 1 60); do
    [[ "$(kubectl -n "$NAMESPACE" get networkchaos delay-api-to-db -o jsonpath='{.status.conditions[?(@.type=="AllInjected")].status}' 2>/dev/null)" == True ]] && break
    sleep 2
  done
  for _ in $(seq 1 10); do
    code="$(traced_read "$(hex 16)")"
    [[ "$code" == 200 ]] && ok=$((ok + 1))
  done
  trace="$(hex 16)"
  code="$(traced_read "$trace")"
  kubectl -n "$NAMESPACE" delete networkchaos delay-api-to-db >/dev/null 2>&1 || :
  [[ "$code" == 200 ]] && ok=$((ok + 1))
  ((ok == 11)) || die "chaos: hypothesis refuted, only $ok/11 reads succeeded with 200 ms between the API and PostgreSQL"
  spans="$(trace_spans "$trace")" || die "chaos: the trace $trace of the slow read is incomplete in Tempo"
  ms="$(awk -F'\t' '$1 == "dx03v2-api" && $2 == "SELECT dx03v2" { print $3; exit }' <<<"$spans")"
  if [[ ! "$ms" =~ ^[0-9]+$ ]] || ((ms < 190)); then
    die "chaos: the query span of the slow read lasted ${ms:-?} ms: the delay was not injected (or not visible)"
  fi
  pass "chaos: 200 ms between the API and PostgreSQL (NetworkChaos): $ok/11 reads succeeded, and the trace shows the delay in the query span (${ms} ms)"
}

main() {
  require_cmd git docker kubectl node ssh base64
  # The tx03v2 platform reads LOCAL_SIZE from the environment; a typo fails here, before any build.
  export LOCAL_SIZE="${LOCAL_SIZE:-default}"
  [[ "$LOCAL_SIZE" == default || "$LOCAL_SIZE" == small ]] || die "LOCAL_SIZE must be default or small (got '$LOCAL_SIZE')"
  log "platform size: $LOCAL_SIZE"
  WORK_DIR="$(mktemp -d)"
  trap cleanup EXIT
  # Until the lab exists, no kubectl call of this script can reach a cluster of the machine.
  export KUBECONFIG="$WORK_DIR/no-cluster"
  export LOCAL_STATE_DIR="${LOCAL_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/dx03v2-platform-local}"
  GIT_SHA="$(git -C "$REPO_ROOT" rev-parse --verify -q HEAD || printf '%040d' 0)"
  prepare_tx03v2
  build_images
  lab up
  LAB_KUBECONFIG="$(lab kubeconfig | tail -n 1)"
  export KUBECONFIG="$LAB_KUBECONFIG"
  GIT_SHA="$PREVIOUS_SHA" DEPLOY_IMAGES="dx03v2-api:previous dx03v2-web:previous" DEPLOY_ALLOW_DIRTY=1 \
    bash "$REPO_ROOT/scripts/deploy-local.sh"
  pass "gitops: deployed previous content $PREVIOUS_SHA from distinct image artifacts"
  probe_namespace
  check_db_backup
  check_mesh
  check_mesh_advanced
  check_observability
  check_tracing
  check_trivy
  check_hpa
  check_zero_downtime
  check_failed_rollout_and_rollback
  # The rollback drill proves that the previous release is restored. Re-promote the tested image
  # before the smoke test so its security-header checks run against this branch's content.
  GIT_SHA="$GIT_SHA" DEPLOY_IMAGES="dx03v2-api:e2e dx03v2-web:e2e" DEPLOY_ALLOW_DIRTY=1 \
    bash "$REPO_ROOT/scripts/deploy-local.sh" >"$WORK_DIR/post-rollback-smoke.log" 2>&1 || {
    cat "$WORK_DIR/post-rollback-smoke.log" >&2
    die "rollback: could not re-promote the tested release for smoke validation"
  }
  [[ "$(api GET /api/info)" == *"$GIT_SHA"* ]] || die "rollback: the tested release was not restored for smoke validation"
  # Keep the write-rate-limit exercise last: the smoke test consumes this client's write budget.
  check_smoke
  check_self_heal
  check_chaos
  check_chaos_db_latency
  printf 'SUMMARY: dx03v2 on the tx03v2 local platform: %d probes passed\n' "$PASSED"
}

main "$@"
