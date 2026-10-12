#!/usr/bin/env bash
# End-to-end test on kind (harness stage e2e, CI job e2e). Steps:
#   1. build dx03v2-api:e2e and dx03v2-web:e2e (skipped with E2E_SKIP_BUILD=1: CI loads the images
#      built by the images job)
#   2. create the cluster dx03v2-e2e from kind/kind-config.yaml and `kind load docker-image`
#   3. create the Secrets db-credentials and app-secrets with random values (never printed)
#   4. kubectl apply -k deploy/k8s/overlays/local and wait for the rollouts
#   5. prove that the namespace enforces Pod Security "restricted"
#   6. port-forward svc/web and run e2e/smoke.mjs against it
#   7. NetworkPolicy probes: throwaway PSA-compliant pods that must (not) reach api:3000/postgres:5432
# On failure it dumps diagnostics (events, describe, logs; never Secret values). The cluster is
# deleted at the end unless KEEP_CLUSTER=1 (a kept cluster is reused, with a fresh namespace).
# Environment:
#   E2E_SKIP_BUILD=1     use the existing dx03v2-api:e2e / dx03v2-web:e2e images
#   KEEP_CLUSTER=1       keep the cluster (delete it later: kind delete cluster --name dx03v2-e2e)
#   E2E_DIAGNOSTICS_DIR  diagnostics directory (default: ${TMPDIR:-/tmp}/dx03v2-harness/e2e-diagnostics)
#   E2E_KIND_INTERNAL=1  this script runs inside a container that drives the host Docker daemon
#                        (docker.sock): join the kind network and use the internal API address
#   KIND_EXPERIMENTAL_DOCKER_NETWORK  Docker network of the kind nodes (kind default: kind)
set -euo pipefail

# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
# shellcheck source=scripts/lib/k8s.sh
source "$REPO_ROOT/scripts/lib/k8s.sh"
export PATH="$REPO_ROOT/.tools/bin:$PATH"

CLUSTER=dx03v2-e2e
NAMESPACE=dx03v2
API_IMAGE=dx03v2-api:e2e
WEB_IMAGE=dx03v2-web:e2e
DIAG_DIR="${E2E_DIAGNOSTICS_DIR:-${TMPDIR:-/tmp}/dx03v2-harness/e2e-diagnostics}"
KIND_NETWORK="${KIND_EXPERIMENTAL_DOCKER_NETWORK:-kind}"

WORK_DIR=""
PF_PID=""
PF_PORT=""
ADMIN_TOKEN_VALUE=""
SMOKE_RESULT=""
PROBES_OK=0

cluster_exists() {
  local clusters
  clusters="$(kind get clusters 2>/dev/null)" || return 1
  grep -qx "$CLUSTER" <<<"$clusters"
}

cleanup() {
  local rc=$?
  if [[ -n "$PF_PID" ]]; then
    kill "$PF_PID" 2>/dev/null || :
    wait "$PF_PID" 2>/dev/null || :
  fi
  if ((rc != 0)) && [[ -n "$WORK_DIR" ]] && cluster_exists; then
    k8s_dump_diagnostics "$NAMESPACE" "$DIAG_DIR"
    if [[ -f "$WORK_DIR/port-forward.log" ]]; then
      cp "$WORK_DIR/port-forward.log" "$DIAG_DIR/port-forward.log"
    fi
    log "diagnostics: $DIAG_DIR"
  fi
  if [[ "${KEEP_CLUSTER:-0}" == 1 ]]; then
    log "KEEP_CLUSTER=1: keeping $CLUSTER (remove it with: kind delete cluster --name $CLUSTER)"
  elif cluster_exists; then
    log "deleting cluster $CLUSTER"
    if ! kind delete cluster --name "$CLUSTER" >/dev/null 2>&1; then
      log "error: could not delete the kind cluster $CLUSTER; delete it by hand"
      rc=1
    fi
  fi
  [[ -z "$WORK_DIR" ]] || rm -rf "$WORK_DIR"
  exit "$rc"
}

build_images() {
  local sha c
  if [[ "${E2E_SKIP_BUILD:-0}" == 1 ]]; then
    for c in "$API_IMAGE" "$WEB_IMAGE"; do
      docker image inspect "$c" >/dev/null 2>&1 || die "E2E_SKIP_BUILD=1 but the image $c does not exist"
    done
    log "using the existing images $API_IMAGE and $WEB_IMAGE"
    return 0
  fi
  sha="$(git -C "$REPO_ROOT" rev-parse --verify -q HEAD || printf unknown)"
  for c in api web; do
    log "building dx03v2-$c:e2e"
    docker build -f "$REPO_ROOT/$c/Dockerfile" --build-arg GIT_SHA="$sha" -t "dx03v2-$c:e2e" "$REPO_ROOT"
  done
}

create_cluster() {
  local reused=0 self networks
  if cluster_exists; then
    log "reusing the existing cluster $CLUSTER"
    reused=1
  else
    kind create cluster --name "$CLUSTER" --config "$REPO_ROOT/kind/kind-config.yaml" --kubeconfig "$KUBECONFIG" --wait 180s
  fi
  if [[ "${E2E_KIND_INTERNAL:-0}" == 1 ]]; then
    # Inside a container the published 127.0.0.1 port of the API server belongs to the host:
    # join the nodes' network and talk to the control plane by its container name instead.
    self="$(hostname)"
    networks="$(docker inspect "$self" --format '{{json .NetworkSettings.Networks}}')"
    if [[ "$networks" != *"\"$KIND_NETWORK\":"* ]]; then
      docker network connect "$KIND_NETWORK" "$self"
    fi
    kind get kubeconfig --internal --name "$CLUSTER" >"$KUBECONFIG"
  else
    kind get kubeconfig --name "$CLUSTER" >"$KUBECONFIG"
  fi
  kubectl version >/dev/null
  if ((reused)); then
    # The PostgreSQL data dies with its pod but the Secrets get new random values: start clean.
    kubectl delete namespace "$NAMESPACE" --ignore-not-found --wait=true --timeout=180s
  fi
  log "cluster $CLUSTER: $(kubectl get nodes --no-headers | awk '{ printf "%s %s %s; ", $1, $2, $5 }')"
}

# The Secrets of contract v1 with random values. stringData goes through stdin, so the values never
# appear in process arguments, logs or the repository.
create_secrets() {
  local db_password
  db_password="$(rand_hex 24)"
  ADMIN_TOKEN_VALUE="$(rand_hex 24)"
  kubectl apply -f "$K8S_DIR/overlays/local/namespace.yaml"
  kubectl apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: db-credentials
  namespace: $NAMESPACE
type: Opaque
stringData:
  DB_HOST: postgres
  DB_PORT: "5432"
  DB_NAME: dx03v2
  DB_USER: dx03v2
  DB_PASSWORD: "$db_password"
---
apiVersion: v1
kind: Secret
metadata:
  name: app-secrets
  namespace: $NAMESPACE
type: Opaque
stringData:
  ADMIN_TOKEN: "$ADMIN_TOKEN_VALUE"
EOF
}

deploy() {
  kubectl apply -k "$K8S_DIR/overlays/local"
  kubectl -n "$NAMESPACE" rollout status statefulset/postgres --timeout=240s
  kubectl -n "$NAMESPACE" rollout status deployment/api --timeout=300s
  kubectl -n "$NAMESPACE" rollout status deployment/web --timeout=240s
  kubectl -n "$NAMESPACE" get pods -o wide
}

check_pod_security() {
  local out
  if out="$(kubectl -n "$NAMESPACE" run psa-probe --image="$API_IMAGE" --restart=Never --dry-run=server \
    --overrides='{"apiVersion":"v1","spec":{"containers":[{"name":"psa-probe","image":"dx03v2-api:e2e","securityContext":{"privileged":true}}]}}' 2>&1)"; then
    die "Pod Security restricted is not enforced: a privileged pod was accepted in $NAMESPACE"
  fi
  [[ "$out" == *'violates PodSecurity "restricted'* ]] || die "the privileged pod was rejected for another reason: $out"
  log "PASS Pod Security restricted rejects a privileged pod in namespace $NAMESPACE"
}

start_port_forward() {
  local pf_log="$WORK_DIR/port-forward.log" i
  kubectl -n "$NAMESPACE" port-forward --address 127.0.0.1 svc/web :8080 >"$pf_log" 2>&1 &
  PF_PID=$!
  for i in $(seq 1 30); do
    PF_PORT="$(sed -nE 's/^Forwarding from 127\.0\.0\.1:([0-9]+) -> 8080$/\1/p' "$pf_log" | head -n 1)"
    if [[ -n "$PF_PORT" ]]; then
      log "port-forward svc/web -> 127.0.0.1:$PF_PORT"
      return 0
    fi
    if ! kill -0 "$PF_PID" 2>/dev/null; then
      cat "$pf_log" >&2
      die "kubectl port-forward exited"
    fi
    sleep 1
  done
  die "kubectl port-forward did not start within ${i}s"
}

run_smoke() {
  local out="$WORK_DIR/smoke.txt" status=0
  BASE_URL="http://127.0.0.1:$PF_PORT" ADMIN_TOKEN="$ADMIN_TOKEN_VALUE" SMOKE_WAIT_SECONDS=60 \
    node "$REPO_ROOT/e2e/smoke.mjs" | tee "$out" || status=$?
  SMOKE_RESULT="$(sed -n 's/^smoke: //p' "$out" | tail -n 1)"
  ((status == 0)) || die "smoke test failed (${SMOKE_RESULT:-no summary})"
}

# probe NAME LABEL HOST PORT -> starts a throwaway pod labelled app.kubernetes.io/name=LABEL that
# opens a TCP connection to HOST:PORT (3 s timeout) and prints connected|timeout|error <code>.
# Returns 0 when it connected, 1 when it could not, 2 when the probe itself did not run. The pod
# is Pod Security "restricted" compliant and uses the API image (already loaded, never pulled).
probe() {
  local name=$1 label=$2 host=$3 port=$4 phase="" result i
  kubectl -n "$NAMESPACE" apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: $name
  labels:
    app.kubernetes.io/name: $label
    app.kubernetes.io/part-of: dx03v2-e2e-probe
spec:
  restartPolicy: Never
  automountServiceAccountToken: false
  enableServiceLinks: false
  terminationGracePeriodSeconds: 1
  securityContext:
    runAsNonRoot: true
    runAsUser: 65532
    runAsGroup: 65532
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: probe
      image: $API_IMAGE
      imagePullPolicy: Never
      args:
        - -e
        - >-
          const s = require('node:net').connect({ host: '$host', port: $port, timeout: 3000 });
          s.on('connect', () => { console.log('connected'); process.exit(0); });
          s.on('timeout', () => { console.log('timeout'); process.exit(3); });
          s.on('error', (e) => { console.log('error ' + e.code); process.exit(4); });
      resources:
        requests:
          cpu: 10m
          memory: 32Mi
        limits:
          memory: 64Mi
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop: [ALL]
EOF
  for i in $(seq 1 90); do
    phase="$(kubectl -n "$NAMESPACE" get pod "$name" -o jsonpath='{.status.phase}' 2>/dev/null)"
    if [[ "$phase" == Succeeded || "$phase" == Failed ]]; then
      break
    fi
    sleep 1
  done
  result="$(kubectl -n "$NAMESPACE" logs "$name" 2>&1 | tail -n 1)"
  kubectl -n "$NAMESPACE" delete pod "$name" --wait=false >/dev/null 2>&1
  if [[ ! "$result" =~ ^(connected|timeout|error\ [A-Z_]+)$ ]]; then
    printf 'the probe pod did not run (phase "%s" after %ss): %s' "$phase" "$i" "$result"
    return 2
  fi
  printf '%s' "$result"
  if [[ "$phase" == Succeeded ]]; then
    return 0
  fi
  return 1
}

expect_probe() { # allowed|blocked NAME LABEL HOST PORT DESCRIPTION
  local want=$1 name=$2 label=$3 host=$4 port=$5 what=$6 result status=0 got
  result="$(probe "$name" "$label" "$host" "$port")" || status=$?
  case "$status" in
    0) got=allowed ;;
    1) got=blocked ;;
    *) die "NetworkPolicy probe $what: $result" ;;
  esac
  [[ "$got" == "$want" ]] || die "NetworkPolicy probe $what: expected $want, got $got ($result)"
  log "PASS NetworkPolicy $what: $got ($result)"
  PROBES_OK=$((PROBES_OK + 1))
}

check_network_policies() {
  local api_ip pg_ip
  # IP addresses avoid any dependency on DNS (allowed for every pod by allow-dns-egress).
  api_ip="$(kubectl -n "$NAMESPACE" get service api -o jsonpath='{.spec.clusterIP}')"
  pg_ip="$(kubectl -n "$NAMESPACE" get pod postgres-0 -o jsonpath='{.status.podIP}')"
  [[ -n "$api_ip" && -n "$pg_ip" ]] || die "could not read the api Service and postgres pod addresses"
  # Positive control first: proves that the probe itself works.
  expect_probe allowed probe-web-api web "$api_ip" 3000 "pod labelled web -> api:3000"
  expect_probe blocked probe-other-api netpol-probe "$api_ip" 3000 "unlabelled pod -> api:3000"
  expect_probe blocked probe-other-pg netpol-probe "$pg_ip" 5432 "unlabelled pod -> postgres:5432"
  expect_probe blocked probe-web-pg web "$pg_ip" 5432 "pod labelled web -> postgres:5432"
}

main() {
  local version
  (($# == 0)) || die "usage: $0 (configuration through environment variables, see the header)"
  require_cmd kind kubectl docker node git
  WORK_DIR="$(mktemp -d)"
  export KUBECONFIG="$WORK_DIR/kubeconfig"
  trap cleanup EXIT
  build_images
  create_cluster
  log "loading $API_IMAGE and $WEB_IMAGE into $CLUSTER"
  kind load docker-image --name "$CLUSTER" "$API_IMAGE" "$WEB_IMAGE"
  create_secrets
  deploy
  check_pod_security
  start_port_forward
  run_smoke
  check_network_policies
  version="$(kubectl get nodes -o jsonpath='{.items[0].status.nodeInfo.kubeletVersion}')"
  printf 'SUMMARY: kind %s (Kubernetes %s): smoke %s; Pod Security restricted enforced; NetworkPolicy probes %d/4 as expected\n' \
    "$CLUSTER" "$version" "$SMOKE_RESULT" "$PROBES_OK"
}

main "$@"
