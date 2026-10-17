# shellcheck shell=bash
# Resolve the deployment path after the verified cluster is reachable.
# resolve_deploy_mode auto|gitops|push -> prints the selected mode; fails closed on API errors.
resolve_deploy_mode() {
  local requested=$1 out
  case "$requested" in
    gitops|push)
      printf '%s\n' "$requested"
      ;;
    auto)
      if out="$(kubectl --namespace argocd get application dx03v2 --output name 2>&1)"; then
        [[ "$out" == application.argoproj.io/dx03v2 ]] || {
          printf 'unexpected Argo CD Application lookup result: %s\n' "$out" >&2
          return 1
        }
        printf 'gitops\n'
      elif [[ "$out" =~ (NotFound|not\ found|doesn.t\ have\ a\ resource\ type|does\ not\ have\ a\ resource\ type) ]]; then
        printf 'push\n'
      else
        printf 'could not determine whether Argo CD owns dx03v2: %s\n' "$out" >&2
        return 1
      fi
      ;;
    *)
      printf 'DEPLOY_MODE must be auto, gitops or push\n' >&2
      return 2
      ;;
  esac
}
