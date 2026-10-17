# shellcheck shell=bash
# Source after common.sh and after the deploy's fixed contract defaults. Only the two IaC-owned
# runtimes are selectable. The global Certificate Map, Cloud Armor policy and deploy identity stay
# project-scoped; the cluster, network, database secrets and image registry are region-specific.
select_region_target() {
  LAB_TARGET="${1:-primary}"
  case "$LAB_TARGET" in
    primary)
      CONTRACT_PARAMETER=tx03v2-lab-contract
      CONTRACT_CLUSTER=tx03v2-lab
      CONTRACT_NETWORK=tx03v2-lab
      CONTRACT_DB_SECRET=tx03v2-lab-db-app
      CONTRACT_ADMIN_TOKEN_SECRET=tx03v2-lab-app-admin-token
      CONTRACT_ADDRESS_NAME=tx03v2-lab-gateway
      GITOPS_BRANCH=gitops/gcp
      ;;
    secondary)
      CONTRACT_PARAMETER=tx03v2-lab-dr-contract
      CONTRACT_CLUSTER=tx03v2-lab-dr
      CONTRACT_NETWORK=tx03v2-lab-dr
      CONTRACT_DB_SECRET=tx03v2-lab-dr-db-app
      CONTRACT_ADMIN_TOKEN_SECRET=tx03v2-lab-dr-app-admin-token
      CONTRACT_ADDRESS_NAME=tx03v2-lab-dr-gateway
      GITOPS_BRANCH=gitops/gcp-dr
      ;;
    *) die 'LAB_TARGET must be primary or secondary' ;;
  esac
  export LAB_TARGET GITOPS_BRANCH
  export CONTRACT_PARAMETER CONTRACT_CLUSTER CONTRACT_NETWORK CONTRACT_DB_SECRET
  export CONTRACT_ADMIN_TOKEN_SECRET CONTRACT_ADDRESS_NAME
}
