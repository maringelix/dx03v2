#!/usr/bin/env bash
# Validate the recovered HTTPS endpoint BEFORE DNS cutover. --resolve preserves TLS SNI and
# certificate verification while forcing every request to the selected region's reserved address.
set -euo pipefail
# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
require_cmd curl jq od tr
(($# == 3)) || die 'usage: regional-smoke.sh HOSTNAME ADDRESS SOURCE_SHA'
hostname=$1 address=$2 revision=$3
[[ "$hostname" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?\.[a-z]{2,}$ ]] || die 'invalid regional hostname'
[[ "$address" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || die 'invalid regional address'
[[ "$revision" =~ ^[0-9a-f]{40}$ ]] || die 'invalid source revision'
work="$(mktemp -d)"
cleanup() { rm -rf -- "${work:?}"; }
trap cleanup EXIT
request() {
  curl --noproxy '*' --fail-with-body --silent --show-error --connect-timeout 10 --max-time 30 \
    --retry 3 --retry-connrefused --resolve "$hostname:443:$address" "$@"
}
curl --noproxy '*' --silent --show-error --max-time 15 --resolve "$hostname:80:$address" \
  -D "$work/headers" -o /dev/null "http://$hostname/api/healthz"
tr -d '\r' <"$work/headers" >"$work/headers-clean"
grep -qE '^HTTP/[0-9.]+ 301([[:space:]]|$)' "$work/headers-clean" || die 'regional HTTP does not redirect'
grep -qiFx "Location: https://$hostname/api/healthz" "$work/headers-clean" || die 'regional redirect has wrong hostname or path'
request "https://$hostname/healthz" >/dev/null
request "https://$hostname/" >"$work/index"
grep -q '<div id="root"' "$work/index" || die 'regional React artifact is absent'
request "https://$hostname/api/info" >"$work/info.json"
jq -e --arg sha "$revision" '.commit == $sha' "$work/info.json" >/dev/null ||
  die 'regional API does not run the requested source revision'
marker="regional-recovery-$(rand_hex 8)"
request --retry 0 --header 'Content-Type: application/json' \
  --data "$(jq -nc --arg text "$marker" '{author:"continuity",text:$text}')" \
  "https://$hostname/api/messages" >"$work/created.json"
id="$(jq -er '.id | select(type == "number")' "$work/created.json")"
request "https://$hostname/api/messages?limit=100" >"$work/messages.json"
jq -e --argjson id "$id" --arg text "$marker" '.items | any(.id == $id and .text == $text)' \
  "$work/messages.json" >/dev/null || die 'regional write is not readable'
log 'PASS selected regional HTTPS endpoint: redirect, React, API revision and acknowledged write/read (DNS unchanged)'
