# CI security and quality

This pipeline runs scanners on pull requests and forks without SonarCloud, a commercial subscription,
production secrets or cloud credentials. Services are disposable and checks fail closed: an
unavailable service, missing report or failed gate fails the required check.

## Static analysis and quality

- **CodeQL** runs JavaScript/TypeScript `security-extended` queries in the `test` job. SARIF is a
  job artifact for seven days; the workflow does not publish findings to GitHub Code Scanning and
  does not need `security-events: write`. The harness blocks security findings with severity
  `>= 7.0` and security findings without numeric severity. Other findings remain visible in the
  report for review.
- **SonarQube Community Build** starts in a container with disposable PostgreSQL and a pinned
  version. SonarScanner is also pinned by version and SHA256 before execution. The job imports
  API and web LCOV, runs the `Sonar way` Quality Gate and fails if the scanner cannot publish or
  retrieve the result.
- Community edition analyzes one main branch per project and does not provide PR decoration.
  Every run uses a new server; the pull-request snapshot is analyzed as `main` on that server and
  the scanner returns the Quality Gate status. This is not multibranch analysis or a Sonar comment
  on the pull-request page.
- Bootstrap replaces the initial `admin/admin` password, creates only disposable projects and
  issues project-scoped analysis tokens. No GitHub Secret is configured: values are generated on
  the runner, used by the scanner, and expire with the disposable service at the end of the job.
- A synthetic fixture outside application sources has more than 20 uncovered lines and an explicit
  LCOV file with zero covered lines. CI sends it to a second project, attaches a disposable gate
  including `coverage < 80%`, and checks by that analysis ID that the gate failed on this condition.
  If the fixture passes or the scanner fails before upload, the check fails.

## Dependencies, configuration and running application

- `make static` uses Trivy for Kubernetes/Docker configuration and fixable HIGH/CRITICAL CVEs in
  dependency manifests. Gitleaks scans Git-visible files and the complete history; the history
  check fails if the tool reports zero commits read. `gitleaks-negative-gate` verifies that a random
  test token is detected and redacted in the report.
- `make build` continues to block fixable HIGH/CRITICAL CVEs in both final images.
- `make dast` uses images already built (`make build` locally; the `images` artifact in CI), starts
  the app and PostgreSQL in a disposable Compose project, and runs OWASP ZAP Baseline with Ajax
  Spider on `127.0.0.1`. It removes containers, network and volume on exit. ZAP runs without extra
  capabilities, an administrator token or cloud access. The `security/dast-baseline.conf` policy
  promotes selected missing headers and protections to `FAIL`; `-I` avoids failing on other
  baseline warnings, which remain visible in reports. The application also sends COEP and CORP,
  checked by the smoke test. HTML and JSON stay outside the repository; CI retains the reports as
  artifacts for seven days. The same check then runs ZAP against a local fixture without CSP,
  marks rule 10038 as `FAIL`, and requires a scanner failure with that finding in JSON.
- Baseline performs spidering and passive analysis. It is not a penetration test or proof that
  vulnerabilities are absent. It sends no credentials and does not replace finding review or the
  harness API and security tests.

## Run and investigate

```bash
make tools
HARNESS_STRICT=1 make verify build
make dast
```

`make dast` needs Docker networking and uses port `18080` by default. Set `ZAP_TARGET_PORT` if
that port is taken. Set `ZAP_REPORT_DIR` to retain reports elsewhere. On a resource-constrained
machine, run the check in GitHub Actions; it is not included in `make all`.

With local `make test` and no `CODEQL_SARIF_PATH`, the harness runs the SARIF parser self-test.
In the GitHub Actions `test` job, CodeQL SARIF is mandatory and evaluated before API and web tests.
The real SonarQube service also runs in Actions; service unavailability does not become `SKIP`.

## Artifact, SBOM and provenance

The `images` job builds each image once, tests the image loaded by the build, and retains its tar,
image IDs and SHA256 for 14 days. The manual `publish-images` workflow runs from `main` for a SHA
whose `ci.yml` push run passed the required source checks. The release verifier currently enumerates
`static`, `test`, `images`, `e2e`, `e2e-platform` and `continuity`; CI also runs
`e2e-platform-small`. Publication checks the tar and image IDs, pushes those same images to GHCR
without rebuilding, and creates SPDX SBOMs whose hashes are recorded in the release bundle.

Trivy scans registry digests. `actions/attest` creates SLSA provenance and SBOM attestations with an
ephemeral Sigstore certificate. The gate checks image digest, repository, publisher workflow,
issuer `https://token.actions.githubusercontent.com`, `main` ref and source SHA, and rejects a
self-hosted runner. The job proves that a missing attestation, different workflow, different issuer
and different source SHA fail verification. The manifest and SPDX files remain in Actions for
90 days.

The `deploy-gcp` workflow receives the publisher run ID and rechecks the publisher, source CI run,
its required checks, SBOM hashes and attestations before requesting `lab` environment approval.
After approval, it copies verified GHCR digests to Artifact Registry without rebuilding, checks
digest and image ID, and publishes manifests by digest through Argo CD or applies the overlay.
Release-bundle verification neither configures nor changes a cloud account.

Copying requires `roles/artifactregistry.writer` on the deployment identity, limited to the
`dx03v2` repository. The `tx03v2` deploy contract already grants it (`docs/CONTRACT.md`); the
identity receives no project-wide image write permission.

The workflow then signs a promotion attestation (`actions/attest`, predicate
`https://github.com/maringelix/tx00v2/attestations/promoted-image/v1`) for each Artifact Registry
digest. The predicate links repository, commit, GHCR source digest and promoted digest. Before
deployment, the workflow checks the signature with `gh attestation verify` (`deploy-gcp.yml`
workflow, GitHub issuer, `main` ref, job commit and no self-hosted runner). The full-profile
`tx03v2` Kyverno `ImageValidatingPolicy` admits app digests from `dx03v2` with this signature;
the separately constrained Google-managed mesh proxy uses Google's image. `deploy-gcp` runs only
from `main` (its first step rejects another ref), because the signature identity is the workflow
on `main`. The deployment script requires the promoted manifest digest to equal the approved source
digest and verifies the image configuration ID as well; it refuses a registry transformation that
changes the approved digest. The attestation protects the final Artifact Registry digest.

## Exercise: prove the gate blocks

1. Remove coverage from a new application block longer than 20 lines. Both the local coverage
   threshold and Sonar Quality Gate should fail; do not lower thresholds or add an ignore.
2. To observe SAST rejection without introducing vulnerable application code, use the SARIF fixture
   of `scripts/check-codeql-sarif.mjs --self-test`: severity `6.9` passes, `7.0` fails, and a
   security finding without severity also fails.
3. Run `HARNESS_ONLY='^gitleaks-negative-gate$' scripts/harness.sh static` to create, detect and
   remove a synthetic secret in a temporary directory. No static token is saved in the repository.
4. Run `make dast`, open `zap.html` and `zap.json` in `ZAP_REPORT_DIR`, and trace an alert back to
   the header, response or route that caused it. Fix the cause and run again;
   `zap-fixture.json` demonstrates that CI fails when CSP is absent.
5. On a fork pull request, verify that the job uses only `contents: read`, generated credentials
   for local Sonar, and no GitHub Secret or cloud identifier.

## Exceptions

This round adds no CodeQL, Sonar, ZAP, Gitleaks or Trivy ignore. A future exception must record the
finding, evidence, reason, owner, mitigation and expiration date. It must pass the existing ignore
guardrails and must never lower global harness thresholds.
