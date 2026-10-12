# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Conventional Commits](https://www.conventionalcommits.org/).

## [Unreleased]

### Changed

- The CI (`static`, `test`, `images`, `e2e`) ran green on GitHub: the README status matrix now says
  `verified in CI` for the rows backed by a CI job (compose stays `verified locally`).
- Dependabot ignores major bumps of the `node` build image (it follows `.nvmrc` and `engines.node`;
  `node:26` failed `npm ci` with EBADENGINE).

### Added

- First version: the dx01v2 app retargeted to GKE Autopilot (the cluster of `tx03v2`, contract v1,
  docs/CONTRATO.md). It started from every tracked file of `dx02v2` (the Azure app, itself the
  dx01v2 app at commit `22e69c4`), with the names changed (`dx02v2` → `dx03v2`, `tx02v2` → `tx03v2`)
  and the Azure path replaced:
  - Google Cloud path: `deploy/k8s/components/gcp` and `overlays/gcp` (Gateway `dx03v2` of class
    `gke-l7-global-external-managed` on the reserved address `tx03v2-lab-gateway` as a
    `NamedAddress`, HTTPRoute `/api` → api:3000 and `/` → web:8080, HealthCheckPolicies `web`
    (`/healthz`) and `api` (`/readyz`), ExternalSecrets from Secret Manager through the
    ClusterSecretStore `gcp-secret-manager`, `verify-full` TLS with the ConfigMap `cloudsql-ca`,
    `TRUST_PROXY_HOPS=2`, HPA 2-4 at 70 % CPU, NetworkPolicies limited to the load balancer ranges
    `35.191.0.0/16` and `130.211.0.0/22`, the Cloud SQL endpoint `/32` and the node DNS cache
    `169.254.20.10`, web memory request raised to the Autopilot minimum) and `components/gcp-waf` /
    `overlays/gcp-waf` (GCPBackendPolicies `api` and `web` with the Cloud Armor policy when
    `waf/security-policy` is not `none`), rendered from `params.example.env` in CI.
  - `scripts/deploy-gcp.sh` and the `deploy-gcp` workflow (`workflow_dispatch` only, environment
    `lab`, `google-github-actions/auth` v3.0.0 with Workload Identity Federation,
    `setup-gcloud` v3.0.1 with gcloud 588.0.0 and `gke-gcloud-auth-plugin`, buildx): renders the
    Parameter Manager parameter `tx03v2-lab-contract` and refuses anything but the 15 contract keys,
    checks the fixed values, the formats, the project, the repository path and that `db/endpoint-ip`
    lies inside `nodes-subnet-cidr`; fetches the kubeconfig through the DNS endpoint; checks the
    platform API groups, the GatewayClass when readable and the RBAC (`kubectl auth can-i`) before
    building; never pushes an existing tag; builds `linux/amd64` images with `docker buildx build
    --push`; trusts only the Cloud SQL root of the contract (SHA-256) and CAs it issued; applies
    `gcp-waf` (or `gcp`, deleting stale GCPBackendPolicies); waits for the ExternalSecrets, the
    rollouts and the Gateway programmed on the contract address; runs the smoke test with
    `SMOKE_EDGE=gke`. Exercised offline with stub CLIs (13 scenarios, docs/HARNESS.md); not run in
    the cloud.
  - Kubeconform schemas for Gateway API v1.5.0 (standard, the version GKE serves), converted from the
    official release asset (SHA-256 pinned), and for `networking.gke.io/v1` HealthCheckPolicy and
    GCPBackendPolicy, copied from datreeio/CRDs-catalog `f3e4382`; `scripts/update-crd-schemas.sh`
    regenerates or checks them (harness check `crd-schemas`).
  - Harness: Google Cloud contract assertions in `scripts/check-manifests.mjs` and `contract-app`
    (manifests, params validation, and the deploy script: keys, fixed values, root SHA-256, overlays,
    read-only gcloud calls); `policy-identifiers` allows only `tx03v2-lab-example`, `000000000000`,
    private or documentation addresses, the two load balancer ranges and `169.254.20.10`;
    `policy-workflows` checks `deploy-gcp.yml` (Workload Identity Federation, pinned gcloud, no
    service account keys); `policy-images` and `scripts/check-build-context.mjs` prove that git and
    every build context leave `gha-creds-*.json` out; `policy-cloud` refuses leftovers of the AWS and
    Azure paths.
  - One API integration test more (`api/test/integration/rate-limit.test.ts`): the
    `[<supplied>,]<client-ip>,<lb-ip>` `X-Forwarded-For` of the Google Cloud Application Load
    Balancer with `TRUST_PROXY_HOPS=2`. It exists only here until it is ported to dx01v2 and dx02v2
    (parity, docs/SUSTENTACAO.md).
  - Brazilian Portuguese docs for the Google Cloud pair: architecture (AWS / Azure / Google Cloud and
    v1 → v2 tables), contract v1 (app side), runbook, guardrails, harness, sustainment (GKE, Gateway
    API, gcloud, Cloud SQL root, parity routine), publication.

### Changed (relative to dx02v2)

- `e2e/smoke.mjs`: `SMOKE_EDGE` accepts `nginx` (default) and `gke` instead of `agc`. Behind the GKE
  Gateway the `/api` CSP is the API's own, and since the load balancer documentation does not say
  how it treats `X-Request-Id`, only the safety property is asserted (a safe client ID comes back
  unchanged or as a UUID, an unsafe one never comes back, two requests never share an ID). The 70 KB
  body gets 413 from the API (Cloud Armor inspects the first 64 KB and never blocks for size).
- Comments in the base manifests, the local namespace and the Dockerfile ignore files (the
  `gha-creds-*.json` exclusion) describe the Google Cloud edge.

### Removed (relative to dx02v2)

- The Azure path: `deploy/k8s/components/azure*`, `deploy/k8s/overlays/azure*`, the
  `alb.networking.azure.io` schemas, `scripts/deploy-azure.sh`, `.github/workflows/deploy-azure.yml`,
  kubelogin from the harness tools, and the Azure contract checks and docs.
