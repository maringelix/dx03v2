# dx03v2 harness

## R9 continuity

The harness runs scripts/continuity-drill.sh through make continuity. The job
checks the images artifact from the images job itself, recovers A/B and tests
failback. [CONTINUITY.md](CONTINUITY.md) defines assertions, measurements and limits.

The harness proves repository claims without a cloud account. Checks live in
scripts/harness.sh; Makefile and CI call them. CI and Linux-container local runs
use HARNESS_STRICT=1. Current checks/stages are listed by scripts/harness.sh list.

## Layers

| Layer | Command | Proves | Does not prove | Runs in |
| --- | --- | --- | --- | --- |
| Tools | make tools | tools/versions.env versions for Trivy, hadolint, actionlint, shellcheck, kubeconform, gitleaks, kind, kubectl, promtool; verifiedSHA256 | ? | local, CI |
| Versions | tool-versions, version-consistency | strict pinned PATH; consistent Node/PostgreSQL/Kubernetes; exact npm versions | ? | local, CI |
| Structure/honesty | repo-structure | required files, status labels, LF, UTF8/noBOM/noUTF16, README<=250lines, executable Git bits, English-only entrypoint | correctness of prose | local, CI |
| Policies | policy-identifiers/workflows/images/app/cloud, trivyignore-policy | placeholder project/number/emails/GUID; private/documentation/LB/node DNS addresses only; pinned actions/images, manual WIF deploy, pinned auth/setup-gcloud/gcloud/plugin/kubectl; gha-creds excluded from Git/build; v1proxy/CORS/inline/HSTS/console regressions, no foreign cloud paths, expiring ignores | author intent | local, CI |
| Dependencies | npm-ci | lock synchronized with three package files, always npm ci in strict mode | dependency security (Trivy) | local, CI |
| Lint/format/types | eslint, prettier, typecheck:api/web | type-aware typescript-eslint, React hooks, format, strict TypeScript | behavior | local, CI |
| Dockerfiles/workflows/scripts | hadolint, actionlint/shellcheck | Dockerfile practices, valid YAML/bash at style level | cloud behavior | local, CI |
| CRD schemas | crd-schemas | generated deploy/k8s/schemas exactly matches source.env: Gateway API1.5.0 official standard-install asset and networking.gke.io catalog f3e4382, each SHA256 checked | same live GKE served version | local, CI/network |
| Manifests | kubeconform, contract-app, promtool-rules, trivy-config | strict rendered local/gcp/gcp-waf/gcp-full/gcp-waf-full/local-platform, Kubernetes 1.36/Gateway API1.5.0/networking.gke.io/v1/ExternalSecret; local-platform experimental HTTPRoute retry schema; check-manifests hardening; twelve bad params rejected. deploy-gcp checks18keys/name/fixed values, one pinned Cloud SQL root/bundle URL, overlays/policy cleanup, auto/attested promotion, DNS endpoint, stdin tokens/masks, allowlisted read-only gcloud, no docker push/password/latest; no HIGH/CRITICAL config | admission/controllers/runtime | local, CI/network |
| Secrets | gitleaks | no recognized secrets, full committed history | unmatched secret patterns | local, CI |
| API tests | test:api | real app/PostgreSQL 17 with supertest, idempotent migrations, create/list/delete, 400/401/404/413/415/429/503, fake-XFF nginx/no-space/Google two-hop formats, readyz200/503, DB recovery, graceful shutdown; >=80%lines/70%branches | Cloud SQL TLS, multiple replicas | local, CI/Docker or DB_* |
| Web tests | test:web | listing, successful/failed submit, validation, admin with mocked fetch, >=70%lines | real browser/CSP enforcement | local, CI |
| Build | npm-build, image:*, image-policy:* | tsc/vite, both images, numeric non-root, OCIlabels, no npm/npx/corepack/shell in API, no web sourcemaps | runtime (E2E) | local, CI/Docker |
| Image vulnerabilities | trivy-image:* | no fixable HIGH/CRITICAL | unfixed CVEs/zero-days | local, CI/Docker/network |
| End to end | kind-e2e/e2e-kind.sh | kind1.36, migration-init rollouts, restricted admission, nginx smoke headers/API201/400/401/204/404/413/429, fakeXFF/request ID, allowed/blocked NetworkPolicies | GKE/managedGateway/LB/Cloud Armor/ESO/Secret Manager/Cloud SQL/Dataplane V2 | local, CI/Docker |
| Cloud | deploy-gcp, contract-app | local overlay/Application-patch rendering/validation | actual GKE deploy/sync/smoke | not run in the cloud (v2) |

Compose smoke (scripts/compose-smoke.sh) uses the same e2e/smoke.mjs, manually
outside CI; see docs/RUNBOOK.md.

## Release and deploy

Manual publish-images publishes CI-approved image IDs to GHCR with SPDX SBOMs and
verifiable attestations. deploy-gcp receives the publication run ID and checks
source CI, digests, SBOM hashes and signer before environment lab, then repeats
verification before requesting Google credentials. After approval it promotes
exact digests to Artifact Registry with crane, without rebuild, and records them in GitOps.

Harness checks structure/inputs and rejection of invalid releases. No real GHCR
publication or cloud run occurred in this round; deployment remains
not run in the cloud (v2).

## DevSecOps

Test evaluates CodeQL security-extended SARIF and a real disposable SonarQube
Quality Gate, including a required failing fixture. Images runs OWASP ZAP Baseline
against disposable Compose; make dast repeats it locally. Gitleaks, Trivy, CodeQL,
Sonar and ZAP gates block and have rejection tests where applicable. Details and
limits: docs/CI_SECURITY.md.

## CI jobs

| Job (ci.yml) | Target | Harness stage |
| --- | --- | --- |
| `static` | make tools && make static | static |
| `test` | CodeQL security-extended, make test against disposable PostgreSQL 17, real disposable SonarQube Quality Gate/negative fixture; SARIF artifact | test |
| `images` | buildx/GitHub cache, make tools && make build, ZAP baseline against disposable Compose; artifact contains both images | build + dast |
| `e2e` | load artifact, install kind/kubectl, make e2e with E2E_SKIP_BUILD=1; diagnostics artifact on failure | e2e |
| `continuity` | load the scanned images; independent A/B recovery, fencing and failback | continuity |
| `e2e-platform` | load artifact; make e2e-platform with E2E_SKIP_BUILD=1; clone deploy/local/tx03v2.ref, start full platform, GitOps deploy and probes (LOCAL_LAB.md); diagnostics | platform |
| `e2e-platform-small` | same artifact/probes with LOCAL_SIZE=small in 7-GB Docker-in-Docker, no swap; memory peaks/OOM summary and diagnostics; not a required ruleset check | platform-small |

`static`, `test`, `images`, `e2e` and `e2e-platform` are stable required ruleset IDs
(`.github/rulesets/main.json`; platform added 2026-10-13). `policy-workflows` prevents accidental
changes. Release verification additionally requires the source CI continuity result.
`promtool-rules` runs `promtool check rules`/`promtool test rules` for local-platform alerts.
`platform-small-e2e` never belongs to `all`: it is heavy and intended for CI runners.

## Strict mode

`HARNESS_STRICT=1`, set in CI/devcontainer, turns every SKIP into FAIL, requires pinned PATH
versions and always executes npm ci. Without strict mode, only a missing local prerequisite
(tool, stopped Docker) can skip a check; the reason is always printed.

| Variable | Effect |
| --- | --- |
| `HARNESS_VERBOSE=1` | print passing-check output |
| `HARNESS_ONLY=<regex>` | local debugging filter, never used in CI; e.g. HARNESS_ONLY='^eslint$' scripts/harness.sh static |
| `HARNESS_WORK_DIR` | logs, rendered manifests, caches; default $TMPDIR/dx03v2-harness |
| `DB_HOST`, `DB_PORT`, `DB_NAME`, `DB_USER`, `DB_PASSWORD` | integration DB; without DB_HOST, create/remove disposable postgres:17-alpine on a random localhost port; with DB_HOST, DB_NAME must end _test because tests recreate tables |
| `IMAGE_TAG` | built/scanned image tag; default e2e, used by local overlay |
| `IMAGES_PREBUILT=1` | build stage checks prebuilt CI images instead of rebuilding |
| `E2E_SKIP_BUILD=1`, `KEEP_CLUSTER=1`, `E2E_DIAGNOSTICS_DIR`, `E2E_KIND_INTERNAL=1` | see scripts/e2e-kind.sh header |

## Adding a check

1. Write `check_<name>` in `scripts/harness.sh`, returning 0/PASS or nonzero/FAIL.
   Use `need <tool>`, `need_docker` or `skip "<reason>"` only for missing prerequisites.
   `summary "<text>"` prints a result even on success.
2. Register in the correct stage (static/test/build/e2e or the relevant platform/continuity stage).
3. Run `scripts/harness.sh list`, `HARNESS_STRICT=1 make verify` and the check's stage.
4. Update this table, `docs/GUARDRAILS.md` if applicable, and CHANGELOG.

For a new tool, add official URLs to `scripts/lib/tools.sh`, pin `tools/versions.env` and run
`scripts/update-tool-checksums.sh <tool> <version>`.

## Windows and macOS

- Windows: use the digest-pinned Node.js 24/Docker-in-Docker devcontainer, or Ubuntu WSL 2.
  Git Bash is unsupported; installed tools are Linux/macOS binaries.
- Apple Silicon macOS: `brew install bash` (system bash 3.2 is insufficient; >=4.4 required)
  or use the devcontainer. Supported tool platforms: linux_amd64, linux_arm64, darwin_arm64.
- Standalone container using host Docker, as in local verification: use
  `mcr.microsoft.com/devcontainers/javascript-node:24-trixie` pinned by digest, Docker/buildx/compose
  copied from official `docker:29-cli`, repo at /work, host Docker socket and named volumes for
  node_modules/.tools/dist outside OneDrive-like synchronized directories.
  Coverage already uses HARNESS_WORK_DIR:

```bash
docker run --rm -e HARNESS_STRICT=1 -v "$PWD:/work" -w /work \
  -v dx03v2-nm-root:/work/node_modules -v dx03v2-nm-api:/work/api/node_modules \
  -v dx03v2-nm-web:/work/web/node_modules -v dx03v2-tools:/work/.tools \
  -v dx03v2-out-api-dist:/work/api/dist -v dx03v2-out-web-dist:/work/web/dist \
  -v dx03v2-npm-cache:/root/.npm -v /var/run/docker.sock:/var/run/docker.sock \
  --network <postgres-network> -e DB_HOST=<postgres-container> -e DB_NAME=dx03v2_test \
  -e DB_USER=... -e DB_PASSWORD <image-above> bash -c "make tools && make verify build"
```

Inside a container, the disposable DB and kind-published 127.0.0.1 belong to the host.
Point DB_* to PostgreSQL on the same Docker network; e2e needs E2E_KIND_INTERNAL=1
(the script joins network kind and uses the API server's internal address).
For different file ownership add
`-e GIT_CONFIG_COUNT=1 -e GIT_CONFIG_KEY_0=safe.directory -e GIT_CONFIG_VALUE_0=*`.

## Data outside the repository

HARNESS_WORK_DIR (default $TMPDIR/dx03v2-harness), or temporary directories, contains logs,
coverage-api/coverage-web, rendered manifests, gitleaks' copied tree, downloaded CRDs and
trivy/kubeconform caches. Only ignored .tools/, node_modules/ and */dist/ remain in the repo;
*/coverage/ appears only with manual npm run test:coverage. `make clean` removes these.

## Troubleshooting

| Symptom | Likely cause | Action |
| --- | --- | --- |
| SKIP tool-versions - missing tools | make tools not run | make tools |
| FAIL npm-ci | lock/package mismatch | npm install, commit both; never hand-edit lock |
| FAIL test:api integration tests need DB_HOST | no Docker/DB_* | start Docker or configure PostgreSQL 17 |
| FAIL test:api DB_NAME does not end _test | variables point at another DB, possibly development | env -u DB_HOST make test for disposable DB, or select *_test |
| FAIL test:api coverage | new code untested | add tests, never lower threshold |
| FAIL trivy-image:* | newly fixable HIGH/CRITICAL | MAINTENANCE5.6 |
| FAIL trivyignore-policy expired | expired exception | fix/remove or renew with new justification |
| FAIL crd-schemas | hand-edited schema/generator changed | update-crd-schemas.sh <Gateway APIversion> <catalogcommit> from source.env, commit output |
| CRD download/hash mismatch | network/changed GitHub content | check network; never accept mismatched hash, stop/investigate |
| kubeconform missing schema | network/uncompilable catalog schema | check network, pinned commits in harness |
| FAIL contract-app | contract v5/hardening mismatch in manifests, params or deploy | correct; interface changes require coordinated TX PR |
| FAIL policy-workflows | missing Check repository variables, wrong auth/setup-gcloud/version, service-account key | follow error, WIF only |
| policy-images gha-creds | dockerignore permits credential context | exclude **/gha-creds-*.json |
| FAIL policy-cloud | foreign filename/service/region outside README/ARCHITECTURE/CHANGELOG | remove or describe GCP equivalent |
| FAIL kind-e2e | rollout/smoke/probe | read summary/E2E_DIAGNOSTICS_DIR/e2e-diagnostics artifact; KEEP_CLUSTER=1 make e2e for investigation |
| FAIL gitleaks | secret/false positive | remove and rotate real credential; use visibly synthetic SHA/GUID placeholders; before first commit scans Git-visible files |
| FAIL policy-identifiers | real project/number/email/GUID/IP | use tx03v2-lab-example, 000000000000, you@example.com, 203.0.113.10 |

## R10: capacity and FinOps

See [Capacity and SLO](FINOPS.md) for bounded load, HPA up/down, PDB/drain, rightsizing,
PostgreSQL pool saturation and showback. Docker evidence runs in Actions; not run in the cloud (v2).
