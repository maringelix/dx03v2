#!/usr/bin/env bash
# Installs the pinned harness tools into .tools/bin.
# Versions come from tools/versions.env, SHA256 from tools/checksums.txt; any mismatch is fatal.
# Usage: scripts/install-tools.sh [tool ...]   (default: every tool). Idempotent.
# Node.js is a prerequisite, not a harness tool (.nvmrc; the devcontainer and CI provide it).
set -euo pipefail

# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
# shellcheck source=scripts/lib/tools.sh
source "$REPO_ROOT/scripts/lib/tools.sh"

TOOLS_DIR="$REPO_ROOT/.tools"

main() {
  local platform tools tool
  require_cmd curl tar install awk
  load_versions
  platform="$(tools_platform)"
  if (($# > 0)); then
    tools=("$@")
  else
    tools=("${TOOLS_ALL[@]}")
  fi
  for tool in "${tools[@]}"; do
    tool_known "$tool" || die "unknown tool '$tool' (known: ${TOOLS_ALL[*]})"
  done
  mkdir -p "$TOOLS_DIR/bin" "$TOOLS_DIR/stamps"
  for tool in "${tools[@]}"; do
    install_one "$tool" "$platform"
  done
  log "tools ready in .tools/ ($platform)"
}

install_one() {
  local tool=$1 platform=$2 version expected stamp tmp artifact actual
  version="$(tool_version "$tool")"
  expected="$(tool_expected_sha "$tool" "$version" "$platform")"
  [[ "$expected" =~ ^[0-9a-f]{64}$ ]] ||
    die "no checksum for $tool $version $platform in tools/checksums.txt (run scripts/update-tool-checksums.sh $tool $version)"
  stamp="$TOOLS_DIR/stamps/$tool"
  if [[ -f "$stamp" && "$(cat "$stamp")" == "$version $expected" && -x "$(tool_installed_path "$tool" "$version" "$TOOLS_DIR")" ]]; then
    log "ok      $tool $version (already installed)"
    return 0
  fi
  [[ "$tool" == shellcheck ]] && require_cmd xz
  tmp="$(mktemp -d)"
  artifact="$(tool_artifact "$tool" "$version" "$platform")"
  download "$(tool_url "$tool" "$version" "$platform")" "$tmp/$artifact"
  actual="$(sha256_of "$tmp/$artifact")"
  if [[ "$actual" != "$expected" ]]; then
    rm -rf "$tmp"
    die "SHA256 mismatch for $tool $version $platform: expected $expected, got $actual. Refusing to install."
  fi
  tool_extract "$tool" "$version" "$platform" "$tmp/$artifact" "$TOOLS_DIR"
  rm -rf "$tmp"
  printf '%s %s\n' "$version" "$expected" >"$stamp"
  log "install $tool $version (sha256 verified)"
}

main "$@"
