#!/usr/bin/env bash
# Offline contract test for auto GitOps/direct deployment selection.
set -euo pipefail

source scripts/lib/deploy-mode.sh
tmp="$(mktemp -d)"
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT

cat >"$tmp/kubectl" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
[[ "$*" == '--namespace argocd get application dx03v2 --output name' ]] || {
  echo "unexpected kubectl call: $*" >&2
  exit 90
}
case "${MOCK_ARGO_RESULT:-present}" in
  present) echo application.argoproj.io/dx03v2 ;;
  namespace-missing) echo 'Error from server (NotFound): namespaces "argocd" not found' >&2; exit 1 ;;
  crd-missing) echo 'error: the server does not have a resource type "applications"' >&2; exit 1 ;;
  forbidden) echo 'Error from server (Forbidden): cannot get applications' >&2; exit 1 ;;
  unavailable) echo 'Unable to connect to the server: timeout' >&2; exit 1 ;;
  *) exit 91 ;;
esac
MOCK
chmod +x "$tmp/kubectl"
PATH="$tmp:$PATH"

[[ "$(resolve_deploy_mode gitops)" == gitops ]]
[[ "$(resolve_deploy_mode push)" == push ]]
[[ "$(MOCK_ARGO_RESULT=present resolve_deploy_mode auto)" == gitops ]]
[[ "$(MOCK_ARGO_RESULT=namespace-missing resolve_deploy_mode auto)" == push ]]
[[ "$(MOCK_ARGO_RESULT=crd-missing resolve_deploy_mode auto)" == push ]]

for failure in forbidden unavailable; do
  if MOCK_ARGO_RESULT="$failure" resolve_deploy_mode auto >/dev/null 2>&1; then
    echo "auto mode must fail closed for $failure errors" >&2
    exit 1
  fi
done

echo "auto mode selects GitOps only for the Argo CD Application and fails closed on lookup errors"
