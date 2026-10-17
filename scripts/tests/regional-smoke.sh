#!/usr/bin/env bash
# Offline HTTP fixtures: DNS remains unchanged, and all TLS calls address the selected region.
set -euo pipefail
# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
work="$(mktemp -d)"
cleanup() { rm -rf -- "${work:?}"; }
trap cleanup EXIT
mkdir "$work/bin" "$work/state"
cat >"$work/bin/curl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$FAKE_STATE/calls"
args=("$@")
headers='' data=''
for ((i=0; i<${#args[@]}; i++)); do
  case "${args[$i]}" in
    -k|--insecure) echo 'TLS verification disabled' >&2; exit 1 ;;
    -D) headers="${args[$((i+1))]}" ;;
    --data) data="${args[$((i+1))]}" ;;
  esac
done
url="${args[${#args[@]}-1]}"
if [[ "$url" == https:* ]]; then
  [[ "$*" == *'--resolve lab.example.com:443:203.0.113.10'* ]] || exit 1
else
  [[ "$*" == *'--resolve lab.example.com:80:203.0.113.10'* ]] || exit 1
fi
case "$url" in
  http:*)
    printf 'HTTP/1.1 301 Moved Permanently\r\nLocation: https://lab.example.com/api/healthz\r\n\r\n' >"$headers"
    ;;
  */healthz) printf 'ok\n' ;;
  https://lab.example.com/) printf '<div id="root"></div>' ;;
  */api/info)
    if [[ "${FAKE_WRONG_REV:-0}" == 1 ]]; then
      printf '{"commit":"1111111111111111111111111111111111111111"}'
    else printf '{"commit":"0000000000000000000000000000000000000000"}'; fi
    ;;
  */api/messages)
    [[ -n "$data" && "$*" == *'--retry 0'* ]] || exit 1
    jq -r '.text' <<<"$data" >"$FAKE_STATE/marker"
    printf '{"id":17}'
    ;;
  */api/messages?limit=100)
    jq -nc --arg text "$(cat "$FAKE_STATE/marker")" '{items:[{id:17,text:$text}]}'
    ;;
  *) echo 'unexpected regional request' >&2; exit 1 ;;
esac
SH
chmod +x "$work/bin/curl"
export FAKE_STATE="$work/state" PATH="$work/bin:$PATH"
bash "$REPO_ROOT/scripts/regional-smoke.sh" lab.example.com 203.0.113.10 \
  0000000000000000000000000000000000000000
[[ -f "$FAKE_STATE/marker" ]] || die 'regional smoke did not verify a real write/read fixture'
rm "$FAKE_STATE/marker"
if FAKE_WRONG_REV=1 bash "$REPO_ROOT/scripts/regional-smoke.sh" lab.example.com 203.0.113.10 \
  0000000000000000000000000000000000000000 >"$work/wrong-revision.log" 2>&1; then
  die 'wrong regional API revision was accepted'
fi
[[ ! -f "$FAKE_STATE/marker" ]] || die 'smoke wrote to an unverified regional API'
if bash "$REPO_ROOT/scripts/regional-smoke.sh" '--bad-host' 203.0.113.10 \
  0000000000000000000000000000000000000000 >"$work/bad-host.log" 2>&1; then
  die 'invalid hostname was accepted'
fi
echo 'PASS regional smoke: selected IP with TLS hostname, expected revision and write/read; wrong revision rejected before writes'
