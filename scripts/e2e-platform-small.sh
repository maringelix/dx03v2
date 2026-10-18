#!/usr/bin/env bash
# The platform e2e (scripts/e2e-platform.sh) on the small size of the tx03v2 platform (LOCAL_SIZE=small),
# inside a Docker daemon limited to SMALL_MEMORY of memory and no swap (Docker-in-Docker): the proof
# that the platform and this app fit in the Docker memory of a laptop (docs/LOCAL_LAB.md). Harness
# stage platform-small, CI job e2e-platform-small. The e2e is the gate; it prints the peak memory of
# the daemon and of the largest containers, and the processes the kernel OOM-killed, if any.
# HEAVY: it needs SMALL_MEMORY free on top of everything else the machine runs, and the inner daemon
# pulls every image of the lab again. It is meant for the CI runner (16 GB). On a 16 GB laptop that
# also runs an editor and a browser, do not run it: use e2e-platform with LOCAL_SIZE=small.
# Environment: SMALL_MEMORY (default 7g, the size measured in docs/LOCAL_LAB.md), E2E_SKIP_BUILD=1
# (copies dx03v2-api:e2e and dx03v2-web:e2e from the outer Docker instead of building them inside),
# TX03V2_REPO (as in e2e-platform.sh), E2E_DIAGNOSTICS_DIR (default
# ${TMPDIR:-/tmp}/dx03v2-harness/platform-diagnostics).
set -euo pipefail

# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

# docker:29.9.0-dind (verified 2026-10-15).
DIND_IMAGE="docker:29.9.0-dind@sha256:0b6d18a4a222e71c88be6034926b4f6cde2fc33c2218643d03ccfddc65995470"
# What scripts/e2e-platform.sh and the install-tools.sh of both repositories need inside. Alpine keeps
# only the latest build of each package in a branch, so the versions follow the pinned base image.
PACKAGES=(bash curl git make unzip xz jq openssh-client nodejs coreutils findutils grep sed gawk tar procps)
NODE=tx03v2-local-control-plane
MEMORY="${SMALL_MEMORY:-7g}"
NAME="dx03v2-small-$$"
DIAG_DIR="${E2E_DIAGNOSTICS_DIR:-${TMPDIR:-/tmp}/dx03v2-harness/platform-diagnostics}"
SAMPLER=""

# -v: the anonymous volume of the inner /var/lib/docker holds every image of the lab (GBs).
cleanup() {
  [[ -z "$SAMPLER" ]] || kill "$SAMPLER" 2>/dev/null || :
  docker rm -f -v "$NAME" >/dev/null 2>&1 || :
}

# Runs inside the Docker-in-Docker container (bash -c "$(declare -f sample_memory); ..."): every 30 s
# the memory of the whole daemon (in use and anonymous: without swap, the anonymous memory cannot be
# reclaimed, and the page cache fills any limit); every minute the working set of each container of the
# kind node (crictl, independent of metrics-server), printing the 12 largest every 5 minutes. The peaks
# go to /work/anon.max and /work/containers.max.
# shellcheck disable=SC2317,SC2329 # invoked inside the container through declare -f
sample_memory() {
  local node=$1 n=0 anon max=0
  while sleep 30; do
    anon="$(sed -n 's/^anon //p' /sys/fs/cgroup/memory.stat)"
    if ((anon > max)); then
      max=$anon
      echo "$max" >/work/anon.max
    fi
    printf 'memory: %d MiB in use, %d MiB anonymous\n' "$(($(cat /sys/fs/cgroup/memory.current) / 1048576))" "$((anon / 1048576))"
    n=$((n + 1))
    ((n % 2 == 0)) || continue
    docker exec "$node" crictl ps -o json >/tmp/ps.json 2>/dev/null || continue
    docker exec "$node" crictl stats -o json >/tmp/stats.json 2>/dev/null || continue
    jq -r --slurpfile s /tmp/stats.json '
      ($s[0].stats | map({key: .attributes.id, value: ((.memory.workingSetBytes.value // "0") | tonumber / 1048576 | floor)}) | from_entries) as $mem
      | .containers[] | [.labels["io.kubernetes.pod.namespace"] + "/" + .labels["io.kubernetes.pod.name"] + "/" + .metadata.name, ($mem[.id] // 0)] | @tsv
    ' /tmp/ps.json >/tmp/now.tsv || continue
    cat /work/containers.max /tmp/now.tsv 2>/dev/null |
      awk -F'\t' '$2 > m[$1] { m[$1] = $2 } END { for (k in m) printf "%s\t%d\n", k, m[k] }' >/tmp/max.tsv
    mv /tmp/max.tsv /work/containers.max
    if ((n % 10 == 0)); then
      sort -t "$(printf '\t')" -k2 -rn /tmp/now.tsv | head -12 | awk -F'\t' '{ printf "  %5d MiB %s\n", $2, $1 }'
    fi
  done
}

gib() {
  awk -v b="$1" 'BEGIN { printf "%.2f GiB", b / 1073741824 }'
}

main() {
  local rc=0 i peak anon events hits oom summary top
  local -a lines=()
  require_cmd docker tar
  [[ "$MEMORY" =~ ^[0-9]+[mg]$ ]] || die "SMALL_MEMORY must look like 7g or 7168m (got '$MEMORY')"
  trap cleanup EXIT
  log "Docker-in-Docker $NAME limited to $MEMORY, no swap"
  docker run -d --privileged --name "$NAME" --memory "$MEMORY" --memory-swap "$MEMORY" "$DIND_IMAGE" >/dev/null
  for i in $(seq 1 60); do
    docker exec "$NAME" docker info >/dev/null 2>&1 && break
    ((i < 60)) && sleep 2
  done
  docker exec "$NAME" docker info >/dev/null 2>&1 || die "the inner Docker daemon did not start"
  docker exec "$NAME" apk add --no-cache "${PACKAGES[@]}" >/dev/null
  tar -C "$REPO_ROOT" --exclude=node_modules --exclude=./.tools -cf - . |
    docker exec -i "$NAME" sh -c 'mkdir -p /work/dx03v2 && tar -C /work/dx03v2 -xf -'
  if [[ "${E2E_SKIP_BUILD:-0}" == 1 ]]; then
    log "copying dx03v2-api:e2e and dx03v2-web:e2e into the inner Docker"
    docker save dx03v2-api:e2e dx03v2-web:e2e | docker exec -i "$NAME" docker load >/dev/null
  fi
  docker exec "$NAME" bash -c "$(declare -f sample_memory); sample_memory $NODE" &
  SAMPLER=$!
  docker exec -e LOCAL_SIZE=small -e E2E_SKIP_BUILD="${E2E_SKIP_BUILD:-0}" -e TX03V2_REPO="${TX03V2_REPO:-}" \
    -e E2E_DIAGNOSTICS_DIR=/work/diagnostics "$NAME" bash -c 'cd /work/dx03v2 &&
      git config --global --add safe.directory "*" &&
      bash scripts/install-tools.sh kubectl >/dev/null && bash scripts/e2e-platform.sh' || rc=$?
  kill "$SAMPLER" 2>/dev/null || :
  SAMPLER=""
  peak="$(docker exec "$NAME" cat /sys/fs/cgroup/memory.peak 2>/dev/null)" || peak=0
  anon="$(docker exec "$NAME" cat /work/anon.max 2>/dev/null)" || anon=0
  events="$(docker exec "$NAME" cat /sys/fs/cgroup/memory.events 2>/dev/null)" || events=""
  # shellcheck disable=SC2016 # expanded by the shell inside the container
  top="$(docker exec "$NAME" sh -c 'sort -t "$(printf "\t")" -k2 -rn /work/containers.max | head -20' 2>/dev/null |
    awk -F'\t' '{ printf "  %5d MiB %s\n", $2, $1 }')" || top=""
  hits="$(awk '$1 == "max" { print $2 }' <<<"$events")"
  oom="$(awk '$1 == "oom_kill" { print $2 }' <<<"$events")"
  summary="Docker limited to $MEMORY: peak $(gib "$peak") (anonymous $(gib "$anon")), limit reached ${hits:-?} times, OOM kills ${oom:-?}"
  # SUMMARY lines: the harness prints them also when the check passes.
  mapfile -t lines <<<"$top"
  printf 'SUMMARY: %s\nSUMMARY: largest containers of the kind node (peak working set):\n' "$summary"
  printf 'SUMMARY: %s\n' "${lines[@]}"
  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    printf '### Platform e2e, size small\n\n%s; e2e exit code %s\n\n<pre>\n%s\n</pre>\n' "$summary" "$rc" "$top" >>"$GITHUB_STEP_SUMMARY"
  fi
  # Under pressure the kernel kills the BestEffort container first (at 7 GB, once in four runs: the
  # plugin copy of Velero, an init container the kubelet runs again). A component that matters breaks
  # the probes, so the kills are reported, not a failure of their own.
  if [[ "$oom" != 0 ]]; then
    docker exec "$NAME" dmesg 2>/dev/null | grep -oE 'Killed process [0-9]+ \([^)]+\)' | sort -u |
      awk '{ print "SUMMARY: OOM-killed: " $0 }' || :
  fi
  if ((rc != 0)); then
    mkdir -p "$DIAG_DIR"
    docker cp "$NAME:/work/diagnostics/." "$DIAG_DIR/" >/dev/null 2>&1 || :
    printf '%s\n' "$events" >"$DIAG_DIR/memory.events"
    printf '%s\n' "$top" >"$DIAG_DIR/largest-containers.txt"
    docker exec "$NAME" dmesg 2>/dev/null | grep -iE 'out of memory|oom-kill|killed process' >"$DIAG_DIR/oom-kills.txt" || :
    log "diagnostics: $DIAG_DIR"
  fi
  return "$rc"
}

main "$@"
