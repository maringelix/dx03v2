# Publishing dx03v2

Initial publication checklist with v2 protections. Follow this order; each item
names its verification point. Repository visibility/settings require explicit
maintainer instruction. Publish together with TX03.

## Before publication

- [ ] Strict make verify/build and make e2e green in Linux/devcontainer.
- [ ] Entrypoint executable bits set before first commit (Windows may lose them):
  `git add --chmod=+x scripts/compose-smoke.sh scripts/dast-zap.sh scripts/deploy-gcp.sh scripts/deploy-local.sh scripts/dev-env.sh scripts/e2e-kind.sh scripts/e2e-platform-small.sh scripts/e2e-platform.sh scripts/get-publish-run-metadata.sh scripts/harness.sh scripts/install-crane.sh scripts/install-sonar-scanner.sh scripts/install-tools.sh scripts/publish-ghcr-images.sh scripts/publish-gitops.sh scripts/render-k8s.sh scripts/repo-guardrails.sh scripts/sonar-bootstrap.sh scripts/sonar-service.sh scripts/test-gitleaks-gate.sh scripts/test-sonar-gate.sh scripts/test-zap-gate.sh scripts/update-crd-schemas.sh scripts/update-tool-checksums.sh scripts/verify-ci-image-artifact.sh scripts/verify-release-bundle.sh`. repo-structure checks Git index.
- [ ] First private main commit pushed; all seven CI jobs green. Ruleset contexts
  and release-source requirements below are deliberately distinct.
- [ ] Full-history gitleaks git clean.
- [ ] policy-identifiers green plus human docs review:no real projects, numbers,
  emails, GUIDs orIPs.
- [ ] Status matrix changes from verified locally to verified in CI only after
  greenCI through a PR; Compose remains local. Managed deploy stays not run in the
  cloud(v2) until cloud_run_report.
- [ ] Repository description/topics, for example gh repo edit maringelix/dx03v2
  --description ... --add-topic kubernetes.

## Publication

- [ ] gh repo edit maringelix/dx03v2 --visibility public --accept-visibility-change-consequences.
- [ ] scripts/repo-guardrails.sh maringelix/dx03v2 applies vulnerability alerts,
  Dependabot security updates, squash-only/delete-merged-branch, issues, read-only
  default token/no PR approval, main ruleset, secret scanning/push protection, private
  reporting, external fork workflow approval, protected lab with invoking reviewer
  and main-only deployment. Fails if Actions disabled, reports applied/skips/notes/
  failures and fork-specific instructions. Fork owners use their own repository.
- [ ] Update other five cloud repositories' family tables from name to a link, one PR each.

## Main ruleset (.github/rulesets/main.json)

- Block deletion/forcepush; require PR, zero reviews for solo maintainer, dismiss
  stale reviews, resolve threads, squash-only merges.
- Required strict checks:static, test, images, e2e, e2e-platform.
- PR-only admin bypass is emergency-only, such as external broken check obstructing
  a security fix; record reason, never conceal implementation failure.

## Stable job IDs

| Workflow | Job | Ruleset required |
|---|---|---|
|ci.yml|static|yes|
|ci.yml|test|yes|
|ci.yml|images|yes|
|ci.yml|e2e|yes|
|ci.yml|e2e-platform|yes|
|ci.yml|continuity|no; release verification requires it|
|ci.yml|e2e-platform-small|no|
|deploy-gcp.yml|deploy|no; manual/protected lab, ID required by policy-workflows|

## Manual release and deploy

publish-images/deploy-gcp are workflow_dispatch only, never triggered by ordinary
CI. On main, publisher takes ci_run_id, requires six source jobs static/test/images/
e2e/e2e-platform/continuity and publishes their approved image IDs, SPDX/attestations.
Small also runsCI but is not enumerated by verify-release-bundle.
Deploy on main takes release_run_id; verify-release checks origin, digests, SBOM hashes
and signer before lab approval/WIF, and repeats before cloud credentials. Then
promote exact digests without rebuild, attest destination and deploy. Publication/
cloud execution have no evidence until explicitly authorized/performed/reported.

## After publication

- [ ] Public main CI/badge green; update matrix with evidence.
- [ ] GCP_PROJECT_ID, GCP_WORKLOAD_IDENTITY_PROVIDER, GCP_DEPLOY_SERVICE_ACCOUNT only
  after TX bootstrap/apply (RUNBOOK section 6).
- [ ] First cloud_run_report recorded.
