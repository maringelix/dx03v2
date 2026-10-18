# Maintaining dx03v2

Routines, support calendar and step-by-step maintenance without a cloud account.
Versions/calendar preserve the historical review of 2026-10-16; check official
schedules before upgrades.

## 1. Goal and scope

Covers API, web, migrations, npm, base images, manifests, CRD schemas, scripts/workflows,
harness tools, DX01/DX02 parity and optional cloud runs. TX03 owns GKE Autopilot,
Cloud SQL, Cloud Armor, Secret Manager, Parameter Manager, Artifact Registry, WIF and
platform infrastructure; its maintenance is documented there.

## 2. Current status

- static/test/build/e2e/platform verified in CI and locally in strict Linux
  containers. CI also runs continuity/platform-small.
- Cloud deployment: not run in the cloud (v2). Harness verifies signed flow; no
  actual GHCR release/cloud deployment occurred in this round.
- Contract v5 (2026-10-17, R9):18 keys and independent secondary. v4 added HTTPS,
  managed mesh and promotion attestation; v3 Argo Application/restricted refresh;
  v2 Collector OTLP endpoint (CONTRACT).
- DX02 app derived from DX01 commit 22e69c4, with section 5.11 differences. Google's two-hop
  XFF integration case originated here and is ported to both siblings.
- No scanner exceptions (.trivyignore.yaml empty).

## 3. Routines

| When | What | How |
| --- | --- | --- |
| Weekly automatic | Monday 06:00UTC all CI jobs, including image Trivy/crd-schemas | section 6; new CVEs, URLs, network |
| Monthly | npm/Docker/actions/pre-commit Dependabot | AGENTS Dependency updater; one PR/group, green CI; same bump in both siblings |
| Quarterly | tools, digests, Node/nginx/GKE, served Gateway API, schemas, gcloud/actions, SQL root, expiring ignores, DX parity | sections 4/5, CHANGELOG |
| Before cloud run | TX costs, green commit, applied TX/platform, GitHub vars | RUNBOOK |
| During | timestamps, smoke output, issues; same-day limit | RUNBOOK |
| After | TX destroy, clean leftovers, cloud_run_report, evidence-backed status | RUNBOOK section 7 |

## 4. Support calendar

| Component | Version | End of support | Source | Action |
| --- | --- | --- | --- | --- |
| Node.js | 24 (.nvmrc; images 24.21.0) | 2028-04-30 | [schedule](https://github.com/nodejs/Release#release-schedule) | Move to 26 after LTS with both siblings, 5.3 |
| TypeScript | 6.0.3 | no published date | [typescript-eslint support](https://typescript-eslint.io/users/dependency-versions) | retain >=4.8.4 <6.1.0 for typescript-eslint 8.71; Dependabot ignores TS minor/major |
| React / Vite / Vitest | 19.3/8.3/5.0 | no published calendar | react.dev, vite.dev, vitest.dev | Separate major PRs; read migration guides |
| Express | 5.3 | active 5.x | [support policy](https://expressjs.com/en/support/) | Dependabot |
| OpenTelemetry JS | API 1.9.1, sdk-trace-node/resources 2.12.0, exporter 0.223.0, semantic-conventions 1.43.0 | API 1 stable, SDK 2, exporter 0 experimental; current-line fixes only | [releases](https://github.com/open-telemetry/opentelemetry-js/releases) | Upgrade together across all three DX repositories; SDK 2/exporter 0.2xx same release; exporter minor can break, run telemetry/tracing/platform tests |
| PostgreSQL | 17, image 17.11, TX Cloud SQL 17 | 2029-11-08 community | [versioning](https://www.postgresql.org/support/versioning/) | Follow TX contract; Compose/CI/kind/harness together |
| nginx (web) | 1.30 stable, 1.30.5-alpine3.24-slim | next stable 1.32 expected ~2027-04 | [nginx](https://nginx.org/en/download.html) | Upgrade next quarterly review after stable release |
| Alpine | 3.24 build/web | ~2028-05 | [releases](https://alpinelinux.org/releases/) | Follow node/nginx digests |
| Distroless | nodejs24-debian13:nonroot | Debian 13 security~2028-08/Node 24 | [distroless](https://github.com/GoogleContainerTools/distroless) | Never debian12, stopped at 24.14.0 |
| Kubernetes | 1.36, node 1.36.4, kubectl 1.36.5, GKE REGULAR 1.36.4-gke.1391002 per 2026-10-08 note | ~2027-06-30 standard per endoflife.date, confirm with GKE | [GKE](https://cloud.google.com/kubernetes-engine/docs/release-schedule), [Kubernetes](https://kubernetes.io/releases/) | Channel updates cluster; coordinate node/kubectl/schema minor with TX, contract change, section 5.5 |
| kind | v0.33.0; its default Kubernetes 1.37.0 | no EOL policy | [releases](https://github.com/kubernetes-sigs/kind/releases) | quarterly; node image from release notes, digest-pinned |
| Gateway API | v1.5.0 standard, GKE>=1.35.2-gke.1842000, Autopilot default; deploy/k8s/schemas | follows GKE | GKE GatewayClass capabilities | Update section 5.7 with TX when served version changes |
| GKE CRDs | networking.gke.io/v1 HealthCheckPolicy/GCPBackendPolicy, catalog f3e4382 | follows GKE; Google publishes no CRD file | [catalog](https://github.com/datreeio/CRDs-catalog) | Quarterly schema diff, section 5.7 |
| Google Cloud CLI | 588.0.0, 2026-10-02, gke-gcloud-auth-plugin | weekly releases, no per-version policy | [notes](https://cloud.google.com/sdk/docs/release-notes) | Quarterly, section 5.9, same TX version |
| `google-github-actions/auth` | v3.0.0 (7c6bc770dae815cd3e89ee6cdf493a5fab2cc093) /setup-gcloud v3.0.1 (aa5489c8933f4cc7a4f7d45035b3b1440c9c10db) | no published date | [auth](https://github.com/google-github-actions/auth/releases), [setup](https://github.com/google-github-actions/setup-gcloud/releases) | Dependabot; update required harness tag checks same PR, 5.8 |
| Cloud SQL root CA | Cloud SQL Root Server CA 0b29df, ECDSA P-384, SHA256 C7B0FCD2...3E59BE | 2049-06-27 | regional storage.googleapis.com/cloudsql-ca-bundles/<region>.pem | Quarterly, section 5.10; root=contract change, subordinates rotate/unpinned |
| Runners | Ubuntu 24.04 LTS, Debian 13 javascript-node:24-trixie | Ubuntu 2029-04 | ubuntu.com, debian.org | Replace before EOL |
| Trivy exceptions | none | — | .trivyignore.yaml | 5.12 if added |

## 5. Procedures

### 5.1 Harness tools

For trivy, hadolint, actionlint, shellcheck, kubeconform, gitleaks, kind or kubectl:

```bash
scripts/update-tool-checksums.sh kubeconform 0.8.1   # download exact upstream release checksums
make tools && HARNESS_STRICT=1 make verify build
git diff tools/                                  # versions.env + checksums.txt
```

The script reads exact-release checksums. Shellcheck publishes none: it downloads three artifacts
and computes SHA256. Read release notes first; a new Trivy version may reveal new findings.

SonarScanner CLI 8.1.0.6389 and crane 0.22.1 are installed separately by workflows;
each installer verifies the official asset SHA256. For SonarScanner, update
scripts/install-sonar-scanner.sh version/hash and run analysis plus the negative
Quality Gate fixture. For crane, review platform hashes in scripts/install-crane.sh
and verify digest copy in the publication path. Never replace checksums with tags.

### 5.2 npm dependencies

Review Dependabot CI/release notes. For manual updates, use exact versions and update the lock:

```bash
npm install --save-exact --workspace api express@5.3.1   # or web, or root without workspace
HARNESS_STRICT=1 make verify build && make e2e
```

Keep TypeScript within typescript-eslint's range, @types/node matching .nvmrc major, and
@vitejs/plugin-react compatible with Vite major. Close an incompatible Dependabot PR with a reason;
never force npm ERESOLVE with --legacy-peer-deps. Port bumps to both siblings (section 5.11).

### 5.3 Node.js major, for example 24 → 26

1. .nvmrc and engines.node in all three package.json files (`>=26 <27`); @types/node 26.
2. Both Dockerfiles use the same digest-pinned `node:26-alpine<version>` builder;
   API runtime `gcr.io/distroless/nodejs26-debian13:nonroot`.
3. Digest-pinned `javascript-node:26-*` devcontainer.
4. `HARNESS_STRICT=1 make verify build && make e2e`; version-consistency finds omissions.

### 5.4 Image digests

```bash
docker buildx imagetools inspect node:24-alpine3.24   # also nginxinc/nginx-unprivileged:1.30-alpine-slim
docker buildx imagetools inspect gcr.io/distroless/nodejs24-debian13:nonroot
docker buildx imagetools inspect postgres:17-alpine
docker buildx imagetools inspect mcr.microsoft.com/devcontainers/javascript-node:24-trixie
```

Use the multi-platform index digest; update tag/date comments. PostgreSQL's digest appears in
Compose, ci.yml, local/postgres.yaml and harness; version-consistency requires all four to agree.
Check the actual in-image version: tags may stop rebuilding. App base-image digests remain
coordinated with dx01v2/dx02v2.

### 5.5 Kubernetes, kind and GKE

1. scripts/update-tool-checksums.sh kind <version>; kind/kind-config.yaml node
   image comes from release notes, always digest-pinned.
2. Pin kubectl to the node minor with update-tool-checksums.sh.
3. Update harness K8S_SCHEMA_KUBERNETES_VERSION and matching K8S_SCHEMA_REF;
   version-consistency requires matching node/kubectl/schema minors.
4. GKE minor follows TX REGULAR channel:coordinated contract change in both repos.

### 5.6 Red Trivy image gate

1. Read trivy-image:* package, installed version and fixed version.
2. Alpine/Debian: refresh base digest (5.4); if unavailable, wait for rebuild or choose another tag.
3. npm: update dependency (5.2); if transitive, use an exact root package.json overrides entry
   explained in the PR.
4. No applicable fix and accepted risk: temporary exception (5.9/GUARDRAILS.md).
   Never reduce severity or disable the gate.

### 5.7 kubeconform catalogs, Gateway API and networking.gke.io

- Harness K8S_SCHEMA_REF(yannh) and CRD_SCHEMA_REF(datreeio, ExternalSecret only)
  are pinned commits. Inspect with:
  gh api 'repos/datreeio/CRDs-catalog/commits?path=external-secrets.io/externalsecret_v1.json&per_page=1'.
- deploy/k8s/schemas/source.env records URL/version/SHA256. When GKE serves a
  different Gateway API or catalog GKE schemas change:

```bash
gh api 'repos/datreeio/CRDs-catalog/commits?path=networking.gke.io/gcpbackendpolicy_v1.json&per_page=1'
scripts/update-crd-schemas.sh v1.5.0 f3e4382095909ac60000da025f323ba44d4c738a
HARNESS_STRICT=1 make verify
git diff deploy/k8s/schemas
```

Review field changes; manifests may need adjustment. Generator rejects the Gateway
asset if SHA256 differs from GitHub's recorded digest. Update source.env date and
section4; never hand-edit JSON.

### 5.8 Actions

Outside Dependabot, use gh api repos/<o>/<r>/git/ref/tags/<tag>. For annotated tags
follow git/tags/<sha>; use commitSHA with vX.Y.Z comment and verify commits/<sha>.
policy-workflows checks auth/setup-gcloud tags:read release notes for inputs and
credential-file behavior, then update check and action together.

### 5.9 gcloud

1. Read [release notes](https://cloud.google.com/sdk/docs/release-notes), use TX version.
2. Update setup-gcloud version in deploy-gcp.yml (X.Y.Z, never latest), section4/README.
3. Check parameter render renderedPayload, artifacts packages list/docker tags list
   and container clusters get-credentials --dns-endpoint output changes.

### 5.10 Cloud SQL root CA

```bash
curl -fsSO https://storage.googleapis.com/cloudsql-ca-bundles/us-central1.pem
awk '/BEGIN CERT/{n++} {print > ("c" n ".pem")}' us-central1.pem
for c in c*.pem; do openssl x509 -in "$c" -noout -subject -issuer -enddate -fingerprint -sha256; done
```

Expect exactly one self-signed CN=Google Cloud SQL Root Server CA 0b29df with the
contract SHA256 and its issued subordinates. Subordinate rotation is normal. New
root requires coordinated TX contract PRs, CLOUDSQL_ROOT_SHA256 in deploy/harness.

### 5.11 Parity with dx01v2/dx02v2, quarterly and after every app change

API/web/e2e, manifest base and local overlay must stay equivalent to source DX02
and therefore DX01, apart from names. Compare each main:

```bash
ref="$(mktemp -d)"
for repo in dx02v2 dx01v2; do
  git clone --quiet "https://github.com/maringelix/$repo.git" "$ref/$repo"
  for d in api web e2e deploy/k8s/base deploy/k8s/overlays/local; do
    mkdir -p "$ref/norm-$repo/$d" && cp -R "$ref/$repo/$d/." "$ref/norm-$repo/$d/"
  done
  grep -rlIE '[dt]x0[12]v2' "$ref/norm-$repo" | xargs -r sed -i -E 's/([dt])x0[12]v2/\1x03v2/g'
  for d in api web e2e deploy/k8s/base deploy/k8s/overlays/local; do
    diff -ru -x node_modules -x dist -x coverage "$ref/norm-$repo/$d" "$d"
  done
done
rm -rf "$ref"
```

Expected DX02 differences, checked 2026-10-12:

- smoke.mjs:nginx/gke SMOKE_EDGE and Gateway X-Request-Id security property;
  Compose/kind assertions remain equal.
- API/web Dockerfile.dockerignore excludes **/gha-creds-*.json auth credentials.
- Comments in base configmap/kustomization/networkpolicies and local namespace.

DX01 differences are those in DX02 MAINTENANCE plus these. Shared API/web comments
about DX02 edge remain. Any other difference is drift:port fix to lagging repo
with one PR each, or explain why it is GCP-only in CHANGELOG.

### 5.12 Trivy exception review

For every entry approaching expired_at, confirm its reason still applies. Renew
with updated justification for at most about seven months, or fix/remove it.

## 6. Incident response

| Situation | First steps |
| --- | --- |
| Red CI | First FAIL/check log; fix code, never weaken check; strict verify/build, E2E |
| Vulnerability | 5.6; Dependabot/advisory patch in all three DX repositories; private report SECURITY |
| Exposed credential | Local dev-env.sh --force and Compose down -v. Cloud:rotate Secret Manager throughTX, wait ESO<=1h, restart API. GitHub:revoke deploy workloadIdentityUser inTX. Maintainer decides history rewrite |
| Cost alert | TX leftovers/destroy; app Gateway creates billed LB |
| Post-destroy leftovers | TX runbook, k8s1-*NEGs, Gateway forwarding rules/backends; cloud_run_report |
| Rejected root/schema | Never accept wrong SHA256; check official sources; root contract section 5.10, schema section 5.7 |

## 7. Cloud run records

Every run creates cloud_run_report with date, region, commits, GKE version, steps, duration,
observed cost, smoke output, issues and leftovers. README status changes only with this evidence.

## 8. Owners

Maintainer: @maringelix (decisions, merges, cloud runs). AI agents follow AGENTS.md.
