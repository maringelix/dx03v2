# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Conventional Commits](https://www.conventionalcommits.org/).

## [Unreleased]
### Added

- Cloud deploy now publishes the app source revision to `gitops/gcp` with example parameters, then
  waits for Argo CD to report that exact revision `Synced` and `Healthy`. Direct push remains
  available when Argo CD is not managing the app.
- Contract version 3 with tx03v2 records the R4 GitOps Application and restricted refresh permission,
  coordinated with [tx03v2#14](https://github.com/maringelix/tx03v2/pull/14).


### Security

- `deploy/local/tx03v2.ref` pins the local platform to the merged tx03v2 R4 commit, so
  `e2e-platform` and `family-ref` check the integrated infrastructure.

- The smoke test never sends the admin token over plain HTTP to another machine (roadmap R3.17): it
  is sent over HTTPS or to `127.0.0.1`; on any other plain HTTP entry point, such as the Google Cloud lab
  (the load balancer of the Gateway answers HTTP only), the one call that needs it is skipped (`SKIP` in the
  output) and `scripts/deploy-gcp.sh` does not even read the token.
- `scripts/repo-guardrails.sh` (same file in the six lab repositories, roadmap R3.15 and R3.18) fails
  instead of skipping when it cannot protect the environment `lab`, leaves only `main` in it, reads it
  back, fails when the OIDC subject of the repository is name-based (the cloud trust expects the
  immutable one with the owner and repository IDs) and refuses an argument that is not the
  repository of the clone.
- `scripts/e2e-platform.sh` keeps the state of its lab in a directory of its own, so a lab you keep
  with `make local-up` in tx03v2 is never adopted and destroyed by it, and reads diagnostics only
  through the kubeconfig of the lab: until the lab exists, `kubectl` has no cluster to reach.
- `make clean` removes things only under the directory of the Makefile, wherever make was started
  from (roadmap R3.18).
- `scripts/lib/k8s.sh` stops when the destination of `rm -rf` is empty (`${dest:?}`, `${tmp:?}`); the
  `policy-app` check keeps a bare variable from coming back there (roadmap R3.18).
- `scripts/deploy-gcp.sh` keeps the Artifact Registry login in a temporary Docker configuration
  directory (`DOCKER_CONFIG`), so `~/.docker/config.json` is never written and the token of the run goes
  away with the directory (roadmap R3.18); the `policy-app` check keeps it that way.
- The integration tests drop and recreate tables (`messages`, `schema_migrations`), and with
  `DB_HOST` set the harness ran them against whatever database `DB_*` pointed at, such as the
  development database of `docs/RUNBOOK.md`. They now refuse a `DB_NAME` that does not end in `_test`,
  both in `api/test/integration/helpers.ts` (`requireTestDatabase`, new unit test `test-database`) and
  in `scripts/harness.sh`; `docs/RUNBOOK.md` shows a separate `dx03v2_test` database.
- `scripts/deploy-local.sh` refuses any kube context but `kind-tx03v2-local`: a cluster of whoever runs
  it, left in the current context, never receives the deploy.
- `deploy/local/tx03v2.ref` follows tx03v2 to the commit where its scripts act only on the lab.

### Changed

- `deploy/local/tx03v2.ref` follows tx03v2 to `bd8978d` (tx03v2#9: the External Secrets of the local lab without the Autopilot CPU limits, and S.8).
- Comments, script messages and docs say "the contract" or point to `docs/CONTRATO.md` instead of
  "contract v1": the contract has been at version 2 since round 1 (roadmap S.8); the README says the deploy script follows contract v2 and HTTPS is outside it.
- The family table of both READMEs links the family hub `tx00v2` (roadmap, family guardrails,
  cross-repo checks).
- `scripts/repo-guardrails.sh` also turns issues on (the issue forms) and requires approval for
  workflow runs from forks of external contributors; the reviewer of the `lab` environment is the gh
  user that runs it. It fails while the workflows of a fork are still disabled and notes a renamed
  repository or a CODEOWNERS that names someone else (tested against a stub gh, then applied to the
  original repository and read back with `gh api` on 2026-10-14).
- The ruleset requires the CI job `e2e-platform` too (`.github/rulesets/main.json`, applied with
  `scripts/repo-guardrails.sh`): the local lab is a merge gate, not only maintainer discipline.
- README status matrix: repository settings as code are applied (read back with `gh api` on
  2026-10-13), no longer `planned`.
- The CI (`static`, `test`, `images`, `e2e`) ran green on GitHub: the README status matrix now says
  `verified in CI` for the rows backed by a CI job (compose stays `verified locally`).
- Dependabot ignores major bumps of the `node` build image (it follows `.nvmrc` and `engines.node`;
  `node:26` failed `npm ci` with EBADENGINE).
- The parity notes (docs/SUSTENTACAO.md sections 2 and 5.11, docs/ARQUITETURA.md) no longer list
  the Google Cloud load balancer case of the rate-limit test as pending: dx01v2 and dx02v2 have it
  too (ported on 2026-10-12).

### Fixed

- `scripts/deploy-local.sh` waits until each Deployment has the expected image tag before checking its
  rollout, so Argo CD sync status cannot make the previous image look like the new release.

- `scripts/deploy-local.sh` waits for the Argo CD sync of the commit it pushed: on a redeploy the
  Application was still Synced and Healthy on the previous commit, and the script went on too early.

### Added

- `LOCAL_SIZE=small` for the platform e2e (roadmap R1.8, the port of dx01v2):
  `scripts/e2e-platform.sh` passes it to the tx03v2 platform, which installs the same components with
  smaller memory limits, short retention and fewer series and workers. `make e2e-platform-small` (CI
  job `e2e-platform-small`, not a required check) runs the 18 probes inside a Docker-in-Docker limited
  to 7 GB without swap and reports the peak memory, the largest containers and any OOM kill. Measured
  on 2026-10-15: the 18 probes pass at 7 GB in about 13 minutes (4.40 GiB of anonymous memory; in one
  of the two runs the kernel killed the plugin copy of Velero twice during the install, an init
  container the kubelet runs again); the goal of the roadmap was 6 GB, and the size stays at 7 GB
  (decision of Bruno). `deploy/local/tx03v2.ref` follows tx03v2 to the commit with the sizes.
- Traces with OpenTelemetry, ported from `dx01v2` (same `api/` code, names only): a SERVER span per
  request (named after the route) and a CLIENT span per PostgreSQL query inside it (parameterized SQL
  only), W3C `traceparent` continued, OTLP/HTTP to `OTEL_EXPORTER_OTLP_ENDPOINT` (off without it).
  Manual spans with `@opentelemetry/api` 1.9.1, `sdk-trace-node` 2.12.0, `exporter-trace-otlp-http`
  0.223.0, `resources` 2.12.0 and `semantic-conventions` 1.43.0, no ESM loader hook; `/healthz` and
  `/readyz` untraced; the shutdown flush takes at most 5 s and never fails because of the Collector.
  Log lines carry `trace_id`/`span_id`, and `/metrics` speaks OpenMetrics with the trace id as an
  exemplar. New unit and integration tests (`telemetry`, `tracing`).
- Contract version 2 with tx03v2: the overlay `local-platform` sends the traces to the Collector of the
  local contract (`tracing.otlp-endpoint`, required by `scripts/deploy-local.sh`), the component `gcp`
  to `opentelemetry-collector.observability.svc:4318` (`not run in the cloud (v2)`; the Collector of
  tx03v2 writes them to Cloud Trace). NetworkPolicies widened only for that: API → Collector (4318)
  and Gateway → Collector (4317, its spans), both over HBONE (15008) in the mesh; `contract-app`
  asserts both.
- `make e2e-platform` has 18 probes (was 13): one trace in Tempo from the Gateway to the query, the
  `trace_id` in the log lines in Loki and in an exemplar in Prometheus; a zero-downtime rollout; 200 ms
  of latency between the API and PostgreSQL (NetworkChaos), every read passes and the trace shows the
  delay in the query span.
- `FORK.md`: forking the app step by step (the steps shared with tx03v2, the local runs, testing against
  your own tx03v2, deploying to your own cloud account, troubleshooting), linked from both READMEs and
  CONTRIBUTING.md; the harness requires it.
- `scripts/e2e-platform.sh` takes `TX03V2_REPO` (an https URL; the CI job `e2e-platform` passes the
  repository variable of the same name): a fork can test against its own tx03v2. A pinned commit that is
  not in that repository fails with a clear message.
- The devcontainer declares 4 CPUs and 8 GB (the platform e2e runs the whole local lab).
- The app on the full local platform of tx03v2 (docs/LAB_LOCAL.md), ported from `dx01v2` and
  `dx02v2`: overlay `local-platform` (Istio Gateway with HTTPS from cert-manager, HTTPRoutes,
  ExternalSecrets from `local-secrets`, HPA, `PeerAuthentication` STRICT, `AuthorizationPolicy` by
  identity, NetworkPolicies with HBONE, ServiceMonitor, five alert rules, a Grafana dashboard);
  `scripts/deploy-local.sh` (images to the lab registry, GitOps repository, Argo CD Application);
  `scripts/e2e-platform.sh` with probes (smoke over HTTPS through the emulated load balancer, mesh,
  observability, Trivy reports, HPA, database backup + restore drill, Argo CD self-heal, chaos
  experiment). Harness checks `promtool-rules` (tool promtool 3.15.0) and `platform-e2e` (stage
  `platform`, `make e2e-platform`, CI job `e2e-platform`); `contract-app` asserts the new overlay.
  The platform e2e is verified locally (13 probes on the tx03v2 local lab, from scratch) and in CI.
- `e2e/smoke.mjs`: `SMOKE_EDGE=istio` for the Istio Gateway of the local platform, which routes `/api`
  straight to the API like the GKE Gateway and keeps an external `X-Request-Id` like nginx (the same
  mode dx02v2 has; the `dx01v2` smoke accepts both API CSPs and has no edge modes).
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
    Balancer with `TRUST_PROXY_HOPS=2`. It started here and was then ported to dx01v2 and dx02v2
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
