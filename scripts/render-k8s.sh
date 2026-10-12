#!/usr/bin/env bash
# Renders a kustomize overlay of deploy/k8s to stdout without writing into the repository.
# Usage: scripts/render-k8s.sh <local|gcp|gcp-waf> [params.env]
#   gcp overlays use deploy/k8s/components/gcp/params.example.env unless a params file is given.
set -euo pipefail

# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
# shellcheck source=scripts/lib/k8s.sh
source "$REPO_ROOT/scripts/lib/k8s.sh"
export PATH="$REPO_ROOT/.tools/bin:$PATH"

usage() {
  echo "usage: $0 <overlay> [params.env]   (overlays: ${K8S_OVERLAYS[*]})" >&2
  exit 2
}

main() {
  (($# >= 1 && $# <= 2)) || usage
  local overlay=$1 o known=0
  for o in "${K8S_OVERLAYS[@]}"; do
    [[ "$o" == "$overlay" ]] && known=1
  done
  ((known)) || usage
  k8s_render "$overlay" "${2:-}"
}

main "$@"
