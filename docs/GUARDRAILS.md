# dx03v2 guardrails

A guardrail combines a rule with enforcement, automated where possible. This document names rules,
enforcement and limits. Types: blocking (fails harness/CI), alert (notifies), process (human/agent
discipline). IDs remain stable, including historical CUSTO/MUD identifiers.

## Rules

| ID | Rule | Reason | Enforcement | Type |
| --- | --- | --- | --- | --- |
| SEC-01 | No committed secrets | public repository; history persists | gitleaks, harness/pre-commit | blocking |
| SEC-02 | No real identifiers: project only tx03v2-lab-example in project paths, registry images, service-account emails and WIF pools; 12-digit number only 000000000000; example.com/org/net emails or placeholder service accounts; zero GUID plus API test vector; only RFC1918/RFC5737 IPs, LB ranges 35.191.0.0/16 and 130.211.0.0/22, node DNS 169.254.20.10 and local ambient kubelet probe 169.254.7.127 | Protect projects, accounts, people and addresses | policy-identifiers | blocking |
| SEC-03 | Random runtime local credentials with dev-env.sh/e2e-kind.sh; ignored .env; example placeholders; no Secret objects in app manifests | no copied default passwords | .gitignore, gitleaks, contract-app | blocking |
| SEC-04 | Google Cloud only through WIF, google-github-actions/auth, protected lab and immutable owner/repository IDs; id-token:write only deploy-gcp deploy and publish-images publish for Sigstore, never CI; no credentials_json/GOOGLE_APPLICATION_CREDENTIALS key or interpolated inputs | No long-lived credentials; publication grants no cloud access; reclaimed account names cannot inherit | policy-workflows; repo-guardrails checks environment sub | blocking |
| SEC-05 | Admin token >=32 characters, constant-time comparison; absent token gives503 admin_disabled | prevent weak tokens/timing disclosure | config.ts; admin-auth/config/messages tests | blocking |
| SEC-06 | Redact Authorization, Cookie and password/token fields; deploy masks project, active account and contract service-account email. Cloud smoke never reads admin token (SEC-10); GHCR/Artifact Registry tokens use stdin and temporary DOCKER_CONFIG (SEC-11) | No credentials/IDs in public logs | logger.ts/logger test; contract-app checks masks and crane auth login --password-stdin | blocking/process |
| SEC-07 | Cloud database TLS trusts only contract SHA256 root and its issued CAs; regional bundle not pinned; APP_ENV=lab requires verify-full | Tampered download cannot become trusted root | deploy-gcp, contract-app single root hash/bundle URL, config test | blocking |
| SEC-08 | Exclude gha-creds-*.json from Git and every image build context, including Dockerfile.dockerignore allowlists | No job credentials in images/commits | policy-images, git check-ignore, check-build-context.mjs | blocking |
| SEC-09 | Tests/scripts act only on owned lab resources: destructive integration tests require database name ending _test; deploy-local only kind-tx03v2-local context | Fork operators may have DB variables or kubectl context for other work | requireTestDatabase/helpers and test-database test; test:api; require_lab_context | blocking |
| SEC-10 | Smoke sends admin token only over HTTPS or127.0.0.1; otherwise skips only the credentialed request. Cloud deploy never reads/sends admin token, including full HTTPS | Prevent credential transmission over public plaintext; preserve least access | smoke.mjs/deploy-gcp; contract-app requires ADMIN_TOKEN empty | blocking |
| SEC-11 | GHCR/Artifact Registry login in temporary DOCKER_CONFIG via private_registry_config; preserve ~/.docker/config.json; rm -rf only with nonempty dest/tmp guards | Remove registry tokens on exit; empty destinations cannot broaden deletion | policy-app | blocking |
| SUP-01 | Tool versions/SHA256 pinned; mismatch fatal | supply chain | install-tools.sh, checksums.txt | blocking |
| SUP-02 | Every action pinned to full40SHA and vX.Y.Z comment; deploy requires auth3.0.0/setup-gcloud3.0.1; gcloud version pinned, never latest | Tags can move | policy-workflows | blocking |
| SUP-03 | Digest-pin every Dockerfile, Compose, manifest, CI, kind and devcontainer/feature image; no latest | Avoid v1 mutable images/floating bases | policy-images | blocking |
| SUP-04 | Exact npm versions and synchronized package-lock | Avoid v1 npm ci ERESOLVE | version-consistency/npm-ci, always npm ci in strict mode | blocking |
| SUP-05 | Install Trivy through install-tools.sh only, never trivy-action/setup-trivy | March 2026 incident GHSA-69fq-xp46-6x23 | policy-workflows | blocking |
| SUP-06 | No fixable HIGH/CRITICAL image CVEs | do not publish known fixable vulnerabilities | trivy-image:api/web | blocking |
| SUP-07 | Match Node major across .nvmrc/engines/builder, PostgreSQL digest across Compose/CI/kind/harness, Kubernetes minor across kind/kubectl/schemas | reject partial upgrades | version-consistency | blocking |
| SUP-08 | Monthly npm/docker/actions/pre-commit Dependabot; grouped minor/patch, separate major | detect drift | dependabot.yml | alert |
| SUP-09 | CRD schemas generated from SHA256-pinned official Gateway API version served by GKE and pinned catalog HealthCheckPolicy/GCPBackendPolicy; never hand-edit | Validate against cluster API | crd-schemas/update-crd-schemas.sh --check | blocking |
| K8S-01 | Strict valid rendered Kubernetes 1.36/Gateway API1.5.0 standard/networking.gke.io/v1/ExternalSecret manifests, pinned schemas | Reject before cluster | kubeconform | blocking |
| K8S-02 | Pod Security restricted: non-root numeric UID, RuntimeDefault, no escalation, all capabilities dropped, read-only root, no token/hostPath/host namespaces, requests/memory limit | Least privilege; GKE namespace enforces restricted | contract-app; kind E2E rejects privileged pod | blocking |
| K8S-03 | Default-deny ingress/egress; allow only DNS, web to API3000, API to local PostgreSQL5432 or cloud PSC/32, two LB ipBlocks without except to web8080/API3000, node DNS 169.254.20.10/32:53, metrics from monitoring | Compromised unrelated pod cannot reach DB/VPC; avoid v1 missing from/unrestricted egress | contract-app/kind E2E network probes | blocking |
| K8S-04 | gcp overlays contain only dx03v2-deployer Role kinds, all labeled app.kubernetes.io/part-of:dx03v2; TX owns namespace/RBAC | Least-privilege deployment | contract-app/can-i preflight | blocking |
| K8S-05 | No HIGH/CRITICAL rendered-manifest/Dockerfile findings | secure configuration | trivy-config | blocking |
| K8S-06 | Cloud ingress only Gateway dx03v2, class gke-l7-global-external-managed, contract address; core HTTP80, full managed HTTPS443/HTTP301; HTTPRoute /api to API3000 and / to web8080, readyz/healthz policies, optional Cloud Armor policies on both Services | One contracted public IP; v1 had three forwarding rules | contract-app | blocking |
| APP-01 | trust proxy is hop count, never true: TRUST_PROXY_HOPS1 local/2 Google; rate limit uses req.ip | Fake XFF cannot bypass limit | policy-app/rate-limit integration including Google format/contract-app/smoke varying fake XFF429 | blocking |
| APP-02 | No CORS middleware (same origin), no HTML escaping before storage; UI renders text as text | Avoid fixed v1 CORS | policy-app/integration/smoke round-trip <b> text | blocking |
| APP-03 | No inline UI styles/scripts: CSP self-only; no published sourcemaps | Avoid v1 unsafe-inline/public source | policy-app/smoke/image-policy:web | blocking |
| APP-04 | Security headers on every nginx response including assets/errors; HSTS HTTPS only; server_tokens off | Avoid v1 HTTP HSTS/preload | policy-app/smoke | blocking |
| APP-05 | JSON errors {error:{code, message, requestId}}, no internals:400, 413, 404, 415, 429, 500, 503 | Avoid v1 all500 responses | integration/smoke | blocking |
| APP-06 | pino-only JSON logs with request ID per line | structured/redacted logs | policy-app forbids console.*, eslint no-console | blocking |
| APP-07 | Browser admin token only in memory | no localStorage/cookie credentials | policy-app | blocking |
| APP-08 | Distroless API without shell/npm/npx/corepack; both images numeric non-root uid:gid and OCI source/revision | reduce attack surface | policy-images, image-policy:api/web, hadolint | blocking |
| APP-09 | API coverage >=80% lines/70% branches; web >=70% lines; exercise real code | Avoid v1 expect(true).toBe(true) | vitest thresholds/test:api/test:web | blocking |
| APP-10 | Never edit applied migration; schema_migrations checksum; transaction per migration, advisory lock | concurrent replicas/initContainers cannot corrupt schema | migrate.ts, migrations tests | blocking |
| APP-11 | Versioned TX contract; coordinated interface PRs | both sides evolve together | CONTRACT.md, contract-app | process |
| APP-12 | Same API/web/e2e behavior in all three DX repositories; port shared fixes to each | Fair cloud comparison | PR template/MAINTENANCE parity routine | process |
| APP-13 | No other-cloud implementation paths/files/manifests/workflows/scripts/docs; README/ARCHITECTURE/CHANGELOG may compare family | Document only implemented behavior | policy-cloud/contract-app | blocking |
| CUSTO-01 | Explicit workflow_dispatch release/deploy; validated ci_run_id/release_run_id, protected lab; GitOps contents:write only deploy | deliberate intent/bounded push rights | policy-workflows, publish-gitops.sh | blocking |
| CUSTO-02 | Same-day TX destroy, clean leftovers and cloud_run_report | Cluster, Cloud SQL, Cloud Armor load balancer bill hourly | RUNBOOK | process |
| CUSTO-03 | Promote signed digest without rebuild; reuse SHA tag only for matching bytes, refuse overwrite; preflight contract/platform/RBAC before promotion/apply | No substituted image or wasted build | deploy-gcp/contract-app, crane copy only, no docker build/push/latest | blocking during deploy |
| CI-01 | Harness owns checks; CI jobs invoke make targets; laptop/cloud workflow share deploy-gcp.sh | Same checks locally/CI | PR review/ci.yml/policy-workflows | process |
| CI-02 | No continue-on-error or success-swallowing workflow fallbacks | Honest gates | policy-workflows | blocking |
| CI-03 | Top-level contents:read; deploy alone elevates contents:write; deploy/publish id-token:write for WIF/attestations; bounded timeout/concurrency, ubuntu24.04, persist-credentials:false | Least privilege/predictability | policy-workflows | blocking |
| CI-04 | CI HARNESS_STRICT=1: SKIP fails, tool versions match; no CI secrets | No silent skipping | ci.yml/harness | blocking |
| CI-05 | e2e loads images job's exact built/scanned artifact | cluster bytes match scanned bytes | ci.yml | process |
| CI-06 | Weekly Monday 06:00UTC CI | detect new CVEs, expiry, broken URLs | ci.yml | alert |
| MUD-01 | Main ruleset requires PR, strict static/test/images/e2e/e2e-platform, no force push | harness every change | ruleset/main.json, repo-guardrails.sh | blocking after publication |
| MUD-02 | Scanner exceptions require statement/expired_at within approximately7months | bounded review | trivyignore-policy | blocking |
| MUD-03 | Conventional Commits, one topic/PR, Unreleased CHANGELOG | readable history | PR template | process |
| DOC-01 | Only evidenced claims with exact status labels; no self-ratings; UTF8 without BOM and LF | Avoid v1 status ahead of evidence | repo-structure/review:labels, size, LF, encoding | blocking |
| DOC-03 | All public documentation, examples, comments and contributor guidance use English; one README links to the central GETTING_STARTED guide | Consistent fork onboarding | repo-structure/review | blocking/process |
| DOC-02 | Docs updated with code | prevent stale instructions | PR template | process |
| AGT-01 | Never mutate cloud without explicit human request for task | cost/security | AGENTS.md | process |
| AGT-02 | Never weaken gates/coverage or add unjustified/unbounded ignores | meaningful harness | AGENTS/checks above | process |
| AGT-03 | Stop/ask for AGENTS-listed situations | costly decisions stay human | AGENTS.md | process |
| LOC-01 | Local app through GitOps/ArgoCD/AppProject dx03v2 only, no direct apply | one owner; v1 had two | deploy-local.sh, gitops probe | blocking in e2e-platform |
| LOC-02 | Local STRICT mTLS, identity AuthorizationPolicy, NetworkPolicy with HBONE/ambient kubelet probes | identity, not IP alone | local-platform contract-app, mesh probe | blocking |
| LOC-03 | Every alert uses exported app/kube-state-metrics series and has a promtool test | v1 paid for Prometheus/Alertmanager without proven alerts | promtool-rules/observability probe | blocking |

## Exceptions

A scanner ignore is an exception. To add one:

1. Confirm it is a deliberate lab choice or cannot currently be fixed, rather
   than a defect that should be corrected.
2. Add id, narrow paths/purls, a statement explaining acceptance/compensating
   controls and expired_at within about seven months to .trivyignore.yaml.
3. Explain the exception in the PR. trivyignore-policy rejects missing reasons/
   dates, expired entries or excessive durations; Trivy stops honoring expired entries.

Other exclusions are fixed and explained by checks:policy-identifiers skips
package-lock.json, tools/checksums.txt and deploy/k8s/schemas (hashes/official CRD
examples verified by crd-schemas), and permits one API test UUID. policy-cloud lets
README, ARCHITECTURE and CHANGELOG compare clouds; shared API/web comments may
describe DX02 edge behavior.

Current Trivy exceptions:none, checked 2026-10-12. Image gates use --ignore-unfixed;
unfixed and LOW/MEDIUM CVEs do not fail builds. trivy-image summaries show full
counts for tracking.

## Limits (what is not guaranteed)

- No Google Cloud v2 run:deploy, ESO/Secret Manager, Gateway/LB, Cloud Armor, Cloud SQL
  verify-full and RBAC preflight are rendered/validated/exercised with simulated
  CLIs, not managed services.
- E2E proves kindnet/kube-network-policies, not GKE Dataplane V2. LB/SQL endpoint/
  node DNS address rules exist only in gcp overlays.
- 35.191.0.0/16 and 130.211.0.0/22 belong to all Google Front Ends, not solely the
  lab's LB; NetworkPolicy narrows source to Google, not this specific Gateway.
- In-memory write limits apply per API replica; N replicas allow up to N times
  the configured rate.
- Admin token is shared, no users/automatic rotation; Secret Manager changes require
  API restart after ESO sync. Cloud smoke neither reads nor sends it; credentialed
  DELETE is skipped.
- GKE policy plurals/status semantics remain live-unverified; implemented preflight
  catches RBAC mismatch before writes.
- --ignore-unfixed does not block unfixed CVEs; weekly CI reevaluates them.
- Cloud full alone implements managed Certificate Map HTTPS/HTTP301; core HTTP.
  Issuance remains unrun. Local TLS uses TX cert-manager/lab CA.
- Before first commit, Gitleaks scans Git-visible tracked/nonignored files; after
  that, full history.
- Executable bits are checked only for scripts already in Git index.

## Verification

```bash
make tools
HARNESS_STRICT=1 make verify
HARNESS_STRICT=1 make build
make e2e
scripts/harness.sh list
```
