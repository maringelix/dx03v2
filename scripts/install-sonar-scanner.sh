#!/usr/bin/env bash
# Install a fixed SonarScanner CLI release after verifying its official SHA256 checksum.
set -euo pipefail

VERSION=8.1.0.6389
ARCHIVE="sonar-scanner-cli-$VERSION-linux-x64.zip"
URL="https://binaries.sonarsource.com/Distribution/sonar-scanner-cli/$ARCHIVE"
SHA256=bb8f709f9cb73352f8d1260a3b3c506c0f41146754bc630762c126d795499d0b

for command in curl find grep sha256sum unzip; do
  command -v "$command" >/dev/null 2>&1 || {
    printf 'error: %s is required\n' "$command" >&2
    exit 1
  }
done
[[ -n "${RUNNER_TOOL_CACHE:-}" ]] || { echo 'error: RUNNER_TOOL_CACHE is required' >&2; exit 1; }
[[ -n "${RUNNER_TEMP:-}" ]] || { echo 'error: RUNNER_TEMP is required' >&2; exit 1; }
[[ -n "${GITHUB_ENV:-}" ]] || { echo 'error: GITHUB_ENV is required' >&2; exit 1; }

temp_dir="$(mktemp -d "$RUNNER_TEMP/sonar-scanner.XXXXXX")"
trap 'rm -rf "$temp_dir"' EXIT
archive_path="$temp_dir/$ARCHIVE"
curl --proto '=https' --tlsv1.2 -fsSL --retry 3 --retry-delay 2 --connect-timeout 20 \
  -o "$archive_path" "$URL"
actual_sha="$(sha256sum "$archive_path" | awk '{print $1}')"
[[ "$actual_sha" == "$SHA256" ]] || {
  echo "error: SonarScanner CLI $VERSION SHA256 mismatch: $actual_sha" >&2
  exit 1
}

install_dir="$RUNNER_TOOL_CACHE/sonar-scanner-cli/$VERSION"
mkdir -p "$install_dir"
unzip -q "$archive_path" -d "$install_dir"
scanner="$(find "$install_dir" -type f -path '*/bin/sonar-scanner' -print -quit)"
[[ -n "$scanner" && -x "$scanner" ]] || { echo 'error: extracted sonar-scanner is missing' >&2; exit 1; }
"$scanner" --version | grep -Fq "$VERSION" || { echo 'error: extracted scanner version mismatch' >&2; exit 1; }
printf 'SONAR_SCANNER=%s\n' "$scanner" >>"$GITHUB_ENV"
echo "Installed SonarScanner CLI $VERSION after SHA256 verification."
