# AGENTS.md

Instructions for AI coding agents and humans working in `dx03v2`. `CLAUDE.md` points here; this file
is the source of truth. The full rule list is [docs/GUARDRAILS.md](docs/GUARDRAILS.md).
All public documentation is written in English. This includes UI text, examples, comments and contributor guidance.
Fork onboarding starts at the [family guide](https://github.com/maringelix/tx00v2/blob/main/docs/GETTING_STARTED.md).

## 1. Mission and context

- `dx03v2` is the application half of the Google Cloud pair (`tx03v2` + `dx03v2`) of a public,
  educational DevOps lab: one infrastructure + application pair per cloud (v2 family in the README).
- The app is the same one as `dx01v2` and `dx02v2` (source commit `22e69c4` of dx01v2), on purpose: a
  small message board (Express 5 + TypeScript API, React 19 page served by nginx-unprivileged,
  PostgreSQL 17). Only the deploy target changes: Kubernetes manifests (kustomize) for kind and for
  the GKE Autopilot cluster of `tx03v2`, with Gateway API on the GKE Gateway controller (global
  external Application Load Balancer) and Cloud Armor.
- It must stay healthy without any cloud account: every claim is backed by the harness or carries a
  status label (`verified in CI`, `verified locally`, `not run in the cloud (v2)`, `planned`).
- Current status: static, test, build and the kind e2e pass locally in Linux containers and in CI
  (jobs `static`, `test`, `images`, `e2e`).
  `scripts/deploy-gcp.sh` was exercised offline with stub `gcloud`/`kubectl`/`docker` only.
  **Nothing of v2 has run in Google Cloud** (`deploy-gcp` is `not run in the cloud (v2)`).
- The app also has an overlay and a GitOps deploy for the full local platform of tx03v2 (kind, Istio
  ambient, Argo CD, Prometheus, Loki, Tempo and the OpenTelemetry Collector, Gatekeeper, Trivy
  Operator, chaos): overlay `local-platform`, `scripts/deploy-local.sh` and `make e2e-platform` (CI job
  `e2e-platform`, [docs/LOCAL_LAB.md](docs/LOCAL_LAB.md)); the platform e2e includes
  the R7.2 release rollback drill. It is not cloud-mutating: agents may run it, one heavy run at a time (Docker with 8 GB, or 7 GB with
  `LOCAL_SIZE=small`; `make e2e-platform-small` is meant for the CI runner).
- The interface with `tx03v2` is [docs/CONTRACT.md](docs/CONTRACT.md) (contract v5, 18 keys, owned by tx03v2; the
  local lab has its own local contract, `lab-system/lab-contract`).

## 2. Non-negotiable rules

1. Never commit secrets or real identifiers (project IDs and numbers, service account e-mails of a
   real project, workload identity provider names, the real name suffix, hostnames, public IPs,
   e-mails). Use `tx03v2-lab-example`, `000000000000`, the suffix `00000000`,
   `<name>@tx03v2-lab-example.iam.gserviceaccount.com`, `you@example.com` and `203.0.113.10`. The
   only public addresses allowed are the load balancer ranges `35.191.0.0/16` and `130.211.0.0/22`,
   the node DNS cache `169.254.20.10` and the Istio ambient probe address `169.254.7.127` of the local
   platform (`policy-identifiers` checks every file). Local
   credentials are generated at runtime (`scripts/dev-env.sh`, `scripts/e2e-kind.sh`).
2. Never run cloud-mutating actions (`scripts/deploy-gcp.sh`, `kubectl`/`helm` against a cloud
   cluster, `gcloud` write commands, dispatching `deploy-gcp`) unless a human explicitly asks for
   that action in the current task. Read-only `gh api` lookups and public HTTP GETs are fine.
3. Never weaken a gate: no `continue-on-error`, no `|| true` on checks, no `--no-verify`, no lowered
   coverage thresholds, no disabled or skipped checks, no new scanner ignores without `statement` +
   `expired_at`.
4. Never widen IAM, network (NetworkPolicy, Gateway, HTTPRoute, load balancer ranges), RBAC or CORS
   without stating why in the PR. Google Cloud access is Workload Identity Federation only, never a
   service account key. The API has no CORS middleware on purpose (same origin).
5. Keep the contract: changes need coordinated PRs in `tx03v2` and `dx03v2` and a version bump.
6. Keep parity with `dx01v2` and `dx02v2`: a change to `api/`, `web/` or `e2e/` is ported to the
   other app repositories, or the PR says why it is Google Cloud-only (docs/MAINTENANCE.md, parity
   routine).
7. Pin every new dependency, action and image (exact npm version + lockfile, 40-char SHA +
   `# vX.Y.Z`, image digest, tool version + SHA256) and update the docs in the same change.
8. Once the ruleset is on, never push to `main`: pull requests only.

## 3. Repo map

```text
api/                    Express 5 API (src/, migrations/*.sql, test/unit, test/integration, Dockerfile)
web/                    React 19 page (src/, nginx/default.conf + security-headers.conf, Dockerfile)
e2e/                    smoke.mjs + lib.mjs: the smoke test for compose, kind, the GKE Gateway and the local platform
deploy/k8s/base/        Deployments, Services, ConfigMap, PDBs, NetworkPolicies, ServiceAccounts
deploy/k8s/overlays/    local (kind: namespace, PostgreSQL), gcp, gcp-waf, gcp-full, gcp-waf-full (GKE Autopilot of tx03v2), local-platform
deploy/k8s/components/  gcp (Gateway, HTTPRoute, HealthCheckPolicies, ExternalSecrets, HPA, load
                        balancer / Cloud SQL / node DNS policies, params), gcp-waf (GCPBackendPolicies), gcp-https
                        (certificate map, HTTP redirect), mesh-demo (the two backends of the mesh exercise), mesh-csm (managed
                        sidecar mesh, profile full), mesh-full (ambient twin) and
                        local-platform (Istio Gateway, mesh policies, ExternalSecrets, HPA, monitoring, params)
deploy/k8s/schemas/     kubeconform schemas: Gateway API from the release asset, networking.gke.io
                        from a pinned catalog commit (scripts/update-crd-schemas.sh, never by hand)
kind/                   kind-config.yaml (node image pinned by digest)
compose.yaml            local stack dx03v2-dev; .env from scripts/dev-env.sh (.env.example has placeholders)
scripts/harness.sh      every check of the harness (stages static, test, build, e2e, platform, platform-small, all, list)
scripts/install-tools.sh            pinned tools into .tools/ (SHA256-verified)
scripts/update-tool-checksums.sh    bump a tool: versions.env + checksums.txt from upstream checksums
scripts/update-crd-schemas.sh       regenerate or check deploy/k8s/schemas (crd-to-jsonschema.mjs converts)
scripts/e2e-kind.sh     kind e2e (cluster dx03v2-e2e); scripts/compose-smoke.sh, scripts/dev-env.sh
scripts/deploy-gcp.sh   Google Cloud deploy (cloud-mutating; used by .github/workflows/deploy-gcp.yml)
scripts/deploy-local.sh GitOps deploy to the tx03v2 local lab (registry, GitOps repository, Argo CD)
scripts/e2e-platform.sh the app on the full local platform + probes (stage platform; LOCAL_SIZE=small)
scripts/e2e-platform-small.sh       the same e2e at the small size in Docker limited to 7 GB (stage platform-small)
deploy/local/           tx03v2.ref: the tx03v2 commit the platform e2e uses
scripts/render-k8s.sh   render an overlay without touching the repo; check-manifests.mjs asserts the contract
scripts/check-build-context.mjs     proves that every Docker build context leaves gha-creds-*.json out
scripts/repo-guardrails.sh          repository settings via gh api (run by the maintainer, and once by every fork owner)
scripts/lib/            shared bash helpers (common, tools, k8s)
tools/                  versions.env and checksums.txt of the harness tools
.github/                ci.yml (static, test, images, e2e, e2e-platform), deploy-gcp.yml, ruleset, templates, Dependabot
.devcontainer/          Node.js 24 + Docker-in-Docker, pinned by digest (runs make tools)
docs/                   English architecture, API, contract, runbook, guardrails, harness, maintenance
FORK.md                 how to fork the lab: what GitHub does not copy, the local lab, your own cloud account
```

## 4. Setup

- Linux or WSL 2 (Ubuntu) with Docker, bash >= 4.4, Node.js 24 (`.nvmrc`), curl, unzip, xz, git,
  make: `make tools`. `make verify` runs `npm ci` itself.
- Windows/macOS: open the repo in the devcontainer (Node.js 24 + Docker-in-Docker; it runs
  `make tools`). macOS without the devcontainer: `brew install bash`.
- The integration tests need PostgreSQL: set `DB_HOST`, `DB_PORT`, `DB_NAME`, `DB_USER`,
  `DB_PASSWORD`, or let the harness start a throwaway `postgres:17-alpine` container. They drop and
  recreate tables, so they refuse a `DB_NAME` that does not end in `_test`.
- No cloud credentials are needed for anything except `deploy-gcp`: the Google Cloud CLI with
  `gke-gcloud-auth-plugin` (installed by the workflow, or `gcloud auth login` on a laptop),
  `GCP_PROJECT_ID`, Docker with buildx and kubectl from `.tools`.

## 5. Harness commands

| Command | Runs | When |
|---|---|---|
| `make tools` | `scripts/install-tools.sh` (all pinned tools) | first time, after a tool bump |
| `make static` | `scripts/harness.sh static`: policies, npm ci, eslint, prettier, tsc, hadolint, actionlint, shellcheck, CRD schemas, kubeconform, contract, promtool rules, trivy config, gitleaks | every change |
| `make test` | `scripts/harness.sh test`: API unit + integration (real PostgreSQL), web tests, coverage gates | every code change |
| `HARNESS_STRICT=1 make verify` | static + test with SKIP = FAIL (CI jobs `static` and `test`) | before every PR |
| `make build` | npm build, both images, image policy, trivy image gate (CI job `images`) | code, Dockerfile or dependency changes |
| `make e2e` | kind cluster, smoke test, Pod Security and NetworkPolicy probes (CI job `e2e`) | manifest, image or app changes |
| `make e2e-platform` | the app on the full tx03v2 local platform through GitOps + probes (CI job `e2e-platform`) | manifest, image or app changes |
| `make e2e-platform-small` | the same e2e at the small platform size inside Docker limited to 7 GB (CI job `e2e-platform-small`) | heavy: CI only |
| `scripts/harness.sh list` | lists all checks | any time |

## 6. Definition of Done

- [ ] `HARNESS_STRICT=1 make verify` green locally (plus `make build` and `make e2e` when images,
      manifests or the app changed); CI green (`static`, `test`, `images`, `e2e`, `e2e-platform`).
- [ ] Docs, README status matrix and `CHANGELOG.md` (`[Unreleased]`) updated in the same PR.
- [ ] No new unexplained scanner ignores; no weakened checks or coverage thresholds.
- [ ] Contract respected (or bumped with a linked `tx03v2` PR); app changes ported to `dx01v2` and
      `dx02v2`.
- [ ] New dependencies pinned; `package-lock.json` in sync; no secrets or real identifiers.

## 7. Playbooks

**Maintainer / maintenance.** Follow [docs/MAINTENANCE.md](docs/MAINTENANCE.md): react to a red
scheduled CI (often a new CVE in a base image), merge monthly Dependabot PRs, run the quarterly
review (harness tools, image digests, Node.js/PostgreSQL/Kubernetes/GKE calendar, the Gateway API
version GKE serves, kubeconform schemas, gcloud, the Cloud SQL CA root of the contract, ignores close
to `expired_at`, parity with `dx01v2` and `dx02v2`).

**Reviewer.** Check the PR template boxes; confirm the harness is green; look for widened
NetworkPolicies/RBAC/Gateway routes or load balancer ranges, CORS or `trust proxy` changes, inline
styles or raw HTML in the UI, unpinned references, service account keys, hand-edited files in
`deploy/k8s/schemas`, ignores without justification, lowered coverage, docs claiming more than the
harness proves, contract changes without a version bump, and app changes that drift from `dx01v2`
and `dx02v2`.

**Dependency updater.** One Dependabot group per PR. Read the release notes (majors: migration
guide). npm: the lockfile must stay in sync (`npm ci` in the harness proves it) and versions stay
exact; `typescript` must stay inside the range supported by `typescript-eslint`. Docker digests:
`api/Dockerfile` and `web/Dockerfile` share the same `node` build image. Actions: confirm the new SHA
matches the tag comment; gcloud is pinned in `deploy-gcp.yml` (`version:` of setup-gcloud). Harness
tools are bumped only with `scripts/update-tool-checksums.sh`; the CRD schemas only with
`scripts/update-crd-schemas.sh`, to the Gateway API version GKE serves on the tx03v2 cluster. Port
npm and image bumps to `dx01v2` and `dx02v2` too (the apps must stay the same).

**Cloud operator** (only with explicit human approval for that action): read the cost section of the
README first (the GKE cluster fee when the free tier is used elsewhere, Cloud SQL and the load
balancer of the Gateway are the biggest items), check that tx03v2 was applied with its platform layer
and that the GitHub variables are set, dispatch `deploy-gcp` (or run `scripts/deploy-gcp.sh` from a
laptop after `gcloud auth login`), follow [docs/RUNBOOK.md](docs/RUNBOOK.md) and the tx03v2 runbook,
always finish with the tx03v2 destroy + leftover check on the same day, and file a
`cloud_run_report` issue with redacted identifiers. Never leave a lab running unattended.

## 8. Common tasks

- Add an API endpoint: route in `api/src/routes/`, input schema in `api/src/validation.ts`, errors
  through `HttpError`; `trackRoute` as the first handler (metrics label); unit + integration tests;
  document it in `docs/API.md`; port it to `dx01v2` and `dx02v2`.
- Add a migration: a new `api/migrations/NNNN_name.sql` (never edit an applied file: the checksum
  check refuses it); the integration tests run every migration.
- Add an environment variable: `api/src/config.ts` (zod schema, readable error), test in
  `api/test/unit/config.test.ts`, then `compose.yaml`, `deploy/k8s/base/configmap.yaml` (or a
  Secret), `docs/API.md`.
- Trace something new: spans are created by hand in `api/src/telemetry.ts` (no auto-instrumentation
  loader); never put request bodies, query values or tokens in span attributes; test it with the
  in-memory processor (`api/test/unit/telemetry.test.ts`, `api/test/integration/tracing.test.ts`);
  port it to `dx01v2` and `dx02v2`.
- Change a security header: `web/nginx/security-headers.conf` (included in every location) and the
  expectations in `e2e/smoke.mjs`.
- Change a NetworkPolicy: update `scripts/check-manifests.mjs` and the probes in `scripts/e2e-kind.sh`.
- Bump the Gateway API schemas (when GKE serves another version): `scripts/update-crd-schemas.sh
  <gateway-api-version> <crds-catalog-commit>`, then `HARNESS_STRICT=1 make verify` and the calendar
  in `docs/MAINTENANCE.md`.
- Bump a harness tool: `scripts/update-tool-checksums.sh <tool> <version>`, then `make tools verify`.
- Add a check: docs/HARNESS.md ("Adding a check").

## 9. When to stop and ask a human

- Any action that changes or costs money in a cloud account, or needs credentials.
- A check fails for a reason outside the repository (upstream outage, a base image CVE without a
  fix, a broken schema catalog, a moved CA bundle or a new Cloud SQL root) — report it; do not
  weaken or skip the check.
- A contract change, an IAM/RBAC/network/CORS widening, or a new scanner ignore.
- An app change that cannot be ported to `dx01v2` and `dx02v2`.
- Rewriting git history, force-pushing, changing repository settings or rulesets.
- Anything that would make a README/doc claim stronger than the evidence.
