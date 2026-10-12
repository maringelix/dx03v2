#!/usr/bin/env bash
# Pins a harness tool to a new version: downloads the upstream checksum file of that exact
# release (shellcheck publishes none, so its artifacts are downloaded and hashed), rewrites the
# tool's lines in tools/checksums.txt and its entry in tools/versions.env.
# Usage: scripts/update-tool-checksums.sh <tool> <version>
set -euo pipefail

# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
# shellcheck source=scripts/lib/tools.sh
source "$REPO_ROOT/scripts/lib/tools.sh"

usage() {
  echo "usage: $0 <tool> <version>   (tools: ${TOOLS_ALL[*]})" >&2
  exit 2
}

WORK_DIR=""
cleanup() {
  [[ -z "$WORK_DIR" ]] || rm -rf "$WORK_DIR"
}
trap cleanup EXIT

main() {
  (($# == 2)) || usage
  local tool=$1 version=${2#v} tmp p artifact sums_url sums_file sum var
  tool_known "$tool" || usage
  [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "version must look like 1.2.3 (got '$2')"
  require_cmd curl awk
  WORK_DIR="$(mktemp -d)"
  tmp="$WORK_DIR"
  declare -A sums_cache=()
  : >"$tmp/new-lines"
  for p in "${TOOLS_PLATFORMS[@]}"; do
    artifact="$(tool_artifact "$tool" "$version" "$p")"
    sums_url="$(tool_checksum_url "$tool" "$version" "$p")"
    if [[ -n "$sums_url" ]]; then
      if [[ -z "${sums_cache[$sums_url]:-}" ]]; then
        sums_file="$tmp/sums.${#sums_cache[@]}"
        download "$sums_url" "$sums_file"
        sums_cache[$sums_url]="$sums_file"
      fi
      sums_file="${sums_cache[$sums_url]}"
      if [[ "$tool" == kubectl ]]; then
        sum="$(tr -d '[:space:]' <"$sums_file")"
      else
        sum="$(awk -v a="$artifact" '{ n = $2; sub(/^\*/, "", n); if (n == a) { print $1; exit } }' "$sums_file")"
      fi
    else
      log "no upstream checksum file for $tool; hashing the downloaded artifact for $p"
      download "$(tool_url "$tool" "$version" "$p")" "$tmp/$artifact"
      sum="$(sha256_of "$tmp/$artifact")"
    fi
    [[ "$sum" =~ ^[0-9a-f]{64}$ ]] || die "could not determine the SHA256 of $artifact"
    printf '%s  %s  %s  %s\n' "$sum" "$tool" "$version" "$p" >>"$tmp/new-lines"
  done

  awk -v tool="$tool" -v rfile="$tmp/new-lines" '
    BEGIN { while ((getline l < rfile) > 0) r[++n] = l }
    /^#/ || NF == 0 { print; next }
    $2 == tool { if (!done) { for (i = 1; i <= n; i++) print r[i]; done = 1 } next }
    { print }
    END { if (!done) for (i = 1; i <= n; i++) print r[i] }
  ' "$REPO_ROOT/tools/checksums.txt" >"$tmp/checksums.txt"
  cat "$tmp/checksums.txt" >"$REPO_ROOT/tools/checksums.txt"

  var="$(tool_version_var "$tool")"
  awk -v var="$var" -v val="$version" '
    index($0, var "=") == 1 { print var "=" val; found = 1; next }
    { print }
    END { if (!found) print var "=" val }
  ' "$REPO_ROOT/tools/versions.env" >"$tmp/versions.env"
  cat "$tmp/versions.env" >"$REPO_ROOT/tools/versions.env"

  log "updated $tool to $version:"
  cat "$tmp/new-lines" >&2
  if [[ "$tool" == kind || "$tool" == kubectl ]]; then
    log "kind/kubectl: also check the node image in kind/kind-config.yaml (same Kubernetes minor, digest"
    log "from the kind release notes) and K8S_SCHEMA_KUBERNETES_VERSION in scripts/harness.sh."
  fi
  log "next: make tools && HARNESS_STRICT=1 make verify, then commit tools/ in one PR."
}

main "$@"
