# shellcheck shell=bash
# Shared helpers for the dx03v2 scripts. Source this file; do not execute it.

if [[ -z "${BASH_VERSINFO[0]:-}" ]] || ((BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4))); then
  echo "error: bash >= 4.4 is required (macOS: use the devcontainer or 'brew install bash')." >&2
  exit 1
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export REPO_ROOT

log() { printf '%s\n' "$*" >&2; }
die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

# require_cmd CMD... -> fails with an actionable message when a command is missing.
require_cmd() {
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || die "'$c' is required but was not found in PATH."
  done
}

# sha256_of FILE -> prints the lowercase hex SHA256 of FILE.
sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    die "sha256sum or shasum is required."
  fi
}

# download URL OUT -> HTTPS-only download with retries; fails on HTTP errors.
download() {
  curl --proto '=https' --tlsv1.2 -fsSL --retry 3 --retry-delay 2 --connect-timeout 20 \
    -o "$2" "$1" || die "download failed: $1"
}

# rand_hex BYTES -> 2*BYTES random lowercase hex characters (secrets for local stacks only).
# od reads exactly BYTES bytes, so no SIGPIPE surprises under `set -o pipefail`.
rand_hex() {
  od -An -N"$1" -tx1 /dev/urandom | tr -d ' \n'
}

# tool_version_var TOOL -> name of the variable in tools/versions.env (kubeconform -> KUBECONFORM_VERSION).
tool_version_var() {
  local t="${1//-/_}"
  printf '%s_VERSION' "${t^^}"
}

# load_versions -> exports every KEY=VALUE of tools/versions.env without executing the file.
load_versions() {
  local line
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^[[:space:]]*(#.*)?$ ]] && continue
    [[ "$line" =~ ^([A-Z0-9_]+)=([A-Za-z0-9._-]+)$ ]] || die "invalid line in tools/versions.env: $line"
    printf -v "${BASH_REMATCH[1]}" '%s' "${BASH_REMATCH[2]}"
    export "${BASH_REMATCH[1]?}"
  done <"$REPO_ROOT/tools/versions.env"
}

# tool_version TOOL -> version pinned in tools/versions.env.
tool_version() {
  local var
  var="$(tool_version_var "$1")"
  [[ -n "${!var:-}" ]] || die "$var is not set in tools/versions.env"
  printf '%s' "${!var}"
}

# env_file_value FILE KEY -> value of KEY=VALUE in a dotenv file, without sourcing it.
env_file_value() {
  awk -v k="$2" 'index($0, k "=") == 1 { print substr($0, length(k) + 2); exit }' "$1"
}
