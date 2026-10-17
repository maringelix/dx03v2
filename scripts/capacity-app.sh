#!/usr/bin/env bash
# R10 app drill. Heavy, Actions-only in this task. No managed-cloud context is accepted.
set -euo pipefail
# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
require_cmd kubectl docker jq
[[ -f "${KUBECONFIG:-}" && "$(kubectl config current-context)" == kind-tx03v2-local ]] ||
  die 'app capacity drill requires the owned kind lab kubeconfig'
[[ "$(docker inspect tx03v2-local-db --format '{{index .Config.Labels "tx03v2.lab"}}')" == local ]] ||
  die 'refusing to lock a database not owned by this local lab'
NS=dx03v2 PROBE=dx03v2-probe NODE='' PAUSED=0
for item in "configmap/capacity" "resourcequota/capacity"; do
  existing="$(kubectl -n "$PROBE" get "$item" --ignore-not-found -o name)" || die 'cannot inventory probe fixtures'
  [[ -z "$existing" ]] || die 'capacity fixture already exists; refusing adoption'
done
existing="$(kubectl -n "$NS" get stresschaos capacity --ignore-not-found -o name)" || die 'cannot inventory stress fixture'
[[ -z "$existing" ]] || die 'stress fixture already exists; refusing adoption'
WORK="$(mktemp -d)"
ORIGINAL_ARGO="$(kubectl -n argocd get statefulset argocd-application-controller -o jsonpath='{.spec.replicas}')"
kubectl -n "$NS" get hpa api -o json >"$WORK/hpa.json"
kubectl -n "$NS" get deployment api -o json >"$WORK/deployment.json"
IMAGE="$(jq -er '.spec.template.spec.containers[] | select(.name=="api") | .image' "$WORK/deployment.json")"
cleanup() {
  local rc=$?
  trap - EXIT
  kubectl -n "$NS" delete stresschaos capacity --ignore-not-found >/dev/null || rc=1
  if [[ -n "$NODE" ]]; then kubectl uncordon "$NODE" >/dev/null || rc=1; fi
  if ((PAUSED)); then
    jq '{spec:{template:{spec:{containers:[.spec.template.spec.containers[] | select(.name=="api") | {name,resources}]}}}}' \
      "$WORK/deployment.json" >"$WORK/restore.json"
    kubectl -n "$NS" patch deployment api --type=strategic --patch-file="$WORK/restore.json" >/dev/null || rc=1
    jq '{spec:.spec}' "$WORK/hpa.json" >"$WORK/restore-hpa.json"
    kubectl -n "$NS" patch hpa api --type=merge --patch-file="$WORK/restore-hpa.json" >/dev/null || rc=1
    kubectl -n argocd scale statefulset argocd-application-controller --replicas="$ORIGINAL_ARGO" >/dev/null || rc=1
  fi
  if ((rc)); then
    kubectl -n "$NS" get pods,hpa,pdb,vpa -o wide >&2 || rc=1
    kubectl -n "$PROBE" get pods,events >&2 || rc=1
  fi
  kubectl -n "$PROBE" delete pod -l lab.capacity/owned=true --ignore-not-found --wait=false >/dev/null || rc=1
  kubectl -n "$PROBE" delete configmap capacity --ignore-not-found >/dev/null || rc=1
  kubectl -n "$PROBE" delete resourcequota capacity --ignore-not-found >/dev/null || rc=1
  rm -rf "$WORK"
  exit "$rc"
}
trap cleanup EXIT
[[ "$(kubectl get nodes -o json | jq '.items | length')" == 3 ]] || die 'capacity app requires LOCAL_TOPOLOGY=ha'
kubectl -n "$PROBE" get configmap capacity >/dev/null 2>&1 && die 'refusing to adopt an existing capacity fixture'
kubectl -n "$PROBE" create configmap capacity --from-file=capacity.mjs="$REPO_ROOT/e2e/capacity.mjs" >/dev/null
kubectl -n "$PROBE" create quota capacity --hard=requests.cpu=2,requests.memory=2Gi,limits.cpu=4,limits.memory=4Gi,pods=10 >/dev/null
if kubectl apply --dry-run=server -f - >"$WORK/quota.log" 2>&1 <<EOF
apiVersion: v1
kind: Pod
metadata: {name: capacity-overbudget, namespace: $PROBE}
spec:
  restartPolicy: Never
  automountServiceAccountToken: false
  securityContext: {runAsNonRoot: true, runAsUser: 65532, seccompProfile: {type: RuntimeDefault}}
  containers:
    - name: client
      image: $IMAGE
      args: [/capacity/capacity.mjs]
      resources: {requests: {cpu: "9", memory: 64Mi}, limits: {cpu: "9", memory: 256Mi}}
      securityContext: {allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: {drop: [ALL]}}
EOF
then die 'namespace quota accepted an expensive workload'; fi
grep -q 'exceeded quota' "$WORK/quota.log" || die 'expensive workload was refused for a reason other than quota'
IP="$(kubectl -n "$NS" get gateway dx03v2 -o jsonpath='{.status.addresses[0].value}')"
HOST=dx03v2.tx03v2.local
load() {
  local name=$1 seconds=$2 concurrency=$3 failure=${4:-0}
  kubectl apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: capacity-$name
  namespace: $PROBE
  labels: {lab.capacity/owned: "true", cost.lab/owner: learner, cost.lab/environment: ci}
spec:
  restartPolicy: Never
  activeDeadlineSeconds: 220
  automountServiceAccountToken: false
  hostAliases: [{ip: "$IP", hostnames: ["$HOST"]}]
  securityContext: {runAsNonRoot: true, runAsUser: 65532, seccompProfile: {type: RuntimeDefault}}
  containers:
    - name: client
      image: $IMAGE
      args: [/capacity/capacity.mjs]
      env:
        - {name: CAPACITY_URL, value: "https://$HOST/api/messages?limit=10"}
        - {name: NODE_EXTRA_CA_CERTS, value: /lab-ca/ca.crt}
        - {name: DURATION_SECONDS, value: "$seconds"}
        - {name: CONCURRENCY, value: "$concurrency"}
        - {name: EXPECT_FAILURE, value: "$failure"}
      resources: {requests: {cpu: 10m, memory: 64Mi}, limits: {cpu: 500m, memory: 256Mi}}
      securityContext: {allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: {drop: [ALL]}}
      volumeMounts: [{name: program, mountPath: /capacity, readOnly: true}, {name: ca, mountPath: /lab-ca, readOnly: true}]
  volumes:
    - {name: program, configMap: {name: capacity}}
    - {name: ca, configMap: {name: lab-ca}}
EOF
}
result() {
  local name=$1
  for _ in $(seq 1 110); do
    phase="$(kubectl -n "$PROBE" get pod "capacity-$name" -o jsonpath='{.status.phase}')"
    [[ "$phase" == Succeeded || "$phase" == Failed ]] && break
    sleep 2
  done
  kubectl -n "$PROBE" logs "capacity-$name" >"$WORK/$name.json"
  [[ "$phase" == Succeeded ]] || { cat "$WORK/$name.json" >&2; die "capacity $name failed"; }
  jq -e '.requests >= 20' "$WORK/$name.json" >/dev/null
  kubectl -n "$PROBE" delete pod "capacity-$name" --wait=false >/dev/null
}
# Pause reconciliation for the bounded imperative experiment; cleanup restores both resources and GitOps.
kubectl -n argocd scale statefulset argocd-application-controller --replicas=0 >/dev/null
PAUSED=1
kubectl -n argocd wait --for=delete pod -l app.kubernetes.io/name=argocd-application-controller --timeout=120s >/dev/null
kubectl -n "$NS" patch hpa api --type=merge -p '{"spec":{"behavior":{"scaleDown":{"stabilizationWindowSeconds":30}}}}' >/dev/null
load baseline 30 4
result baseline
BEFORE="$(kubectl -n "$NS" get deployment api -o jsonpath='{.spec.replicas}')"
load stressed 180 4
kubectl apply -f - >/dev/null <<EOF
apiVersion: chaos-mesh.org/v1alpha1
kind: StressChaos
metadata: {name: capacity, namespace: $NS}
spec:
  mode: all
  selector:
    namespaces: [$NS]
    labelSelectors: {app.kubernetes.io/name: api}
  stressors: {cpu: {workers: 1, load: 80}}
  duration: 210s
EOF
for _ in $(seq 1 60); do
  [[ "$(kubectl -n "$NS" get deployment api -o jsonpath='{.status.readyReplicas}')" == 4 ]] && break
  sleep 2
done
[[ "$(kubectl -n "$NS" get deployment api -o jsonpath='{.status.readyReplicas}')" == 4 ]] ||
  die 'app HPA did not scale to four healthy replicas under bounded CPU stress and HTTP load'
NODE="$(kubectl -n "$NS" get pods -l app.kubernetes.io/name=api -o json |
  jq -er '[.items[].spec.nodeName | select(startswith("tx03v2-local-worker"))][0]')"
[[ "$(docker inspect "$NODE" --format '{{index .Config.Labels "io.x-k8s.kind.cluster"}}')" == tx03v2-local ]] ||
  die 'refusing foreign node drain'
kubectl drain "$NODE" --pod-selector=app.kubernetes.io/name=api --ignore-daemonsets --delete-emptydir-data --timeout=120s >/dev/null
kubectl -n "$NS" rollout status deployment/api --timeout=120s >/dev/null
result stressed
kubectl uncordon "$NODE" >/dev/null
NODE=''
kubectl -n "$NS" delete stresschaos capacity >/dev/null
# Request rightsizing is a candidate measurement, never an automatic VPA action.
kubectl -n "$NS" set resources deployment/api -c api --requests=cpu=50m,memory=128Mi --limits=cpu=500m,memory=256Mi >/dev/null
kubectl -n "$NS" rollout status deployment/api --timeout=180s >/dev/null
for _ in $(seq 1 120); do
  [[ "$(kubectl -n "$NS" get deployment api -o jsonpath='{.spec.replicas}')" == 2 ]] && break
  sleep 2
done
[[ "$(kubectl -n "$NS" get deployment api -o jsonpath='{.spec.replicas}')" == 2 ]] || die 'app HPA did not scale down after stress'
load rightsized 30 4
result rightsized
AFTER="$(kubectl -n "$NS" get deployment api -o jsonpath='{.spec.replicas}')"
# Saturate real database/pool capacity with a finite table lock; the client must observe errors.
load saturated 20 32 1
kubectl -n "$PROBE" wait pod/capacity-saturated --for=condition=Ready --timeout=90s >/dev/null
docker exec -d tx03v2-local-db psql -U dx03v2 -d dx03v2 -v ON_ERROR_STOP=1 -c \
  'BEGIN; LOCK TABLE messages IN ACCESS EXCLUSIVE MODE; SELECT pg_sleep(10); COMMIT;'
BLOCKED=0
for _ in $(seq 1 15); do
  BLOCKED="$(docker exec tx03v2-local-db psql -At -U dx03v2 -d dx03v2 -c \
    "SELECT count(*) FROM pg_stat_activity WHERE application_name='dx03v2-api' AND wait_event_type='Lock'")"
  ((BLOCKED >= 10)) && break
  sleep 1
done
((BLOCKED >= 10)) || die 'database saturation did not fill an API connection pool'
result saturated
kubectl -n "$NS" rollout status deployment/api --timeout=120s >/dev/null
load recovered 30 4
result recovered
kubectl -n "$NS" get vpa api-recommendation -o json | jq -e '.spec.updatePolicy.updateMode == "Off" and
  (.status.recommendation.containerRecommendations | length > 0)' >/dev/null || die 'API VPA recommendation is absent'
OUT="${E2E_DIAGNOSTICS_DIR:-$WORK}/capacity-app.json"
mkdir -p "$(dirname "$OUT")"
jq -n --argjson before "$BEFORE" --argjson after "$AFTER" --argjson blocked "$BLOCKED" \
  --slurpfile baseline "$WORK/baseline.json" --slurpfile stressed "$WORK/stressed.json" \
  --slurpfile rightsized "$WORK/rightsized.json" --slurpfile saturated "$WORK/saturated.json" --slurpfile recovered "$WORK/recovered.json" \
  '{baseline:$baseline[0],underStressAndDrain:$stressed[0],rightsized:$rightsized[0],saturated:$saturated[0],
    recovered:$recovered[0],databaseBlockedConnections:$blocked,hpa:{peak:4,afterStress:2,afterCandidate:$after},
    requestedCpuMillicores:{before:($before*100),candidate:($after*50)},vpa:"Off",
    limitation:"Requests estimate; no managed-node scaling, cloud invoice or Spot savings claim"}' >"$OUT"
cat "$OUT"
log 'PASS app capacity: real Gateway SLO before/after rightsizing, HPA up/down, drain, database saturation/recovery and VPA Off'
