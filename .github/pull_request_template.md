## What and why

<!-- One or two sentences. Link the issue if there is one. -->

## Definition of Done

- [ ] `make verify` passes locally (or in the devcontainer) with `HARNESS_STRICT=1`; `make build` and `make e2e` too when images, manifests or the app changed
- [ ] CI is green (`static`, `test`, `images`, `e2e`)
- [ ] Docs updated in this PR (README status matrix, docs/*, CHANGELOG `[Unreleased]`)
- [ ] No new scanner ignore, or each new one has `statement` + `expired_at` and is explained below
- [ ] No coverage threshold lowered and no check disabled or skipped
- [ ] No IAM role, network (NetworkPolicy, Gateway, HTTPRoute, Cloud Armor), RBAC or CORS widening, or the reason is stated below
- [ ] Contract (docs/CONTRATO.md) unchanged, or version bumped with a coordinated tx03v2 PR linked below
- [ ] App changes (`api/`, `web/`, `e2e/`) ported to dx01v2 and dx02v2 too, or the reason they stay Google Cloud-only is stated below
- [ ] Every new dependency, action or image is pinned (exact npm version + lockfile / commit SHA / digest)
- [ ] No secrets or real identifiers (project IDs or numbers, service account e-mails, IPs, e-mails) in code, docs or examples

## Cloud impact

<!-- "None" for app/harness/docs changes that do not touch deploy-gcp. Otherwise: what changes in
     the GKE deploy and the cost impact. Nothing here has run in Google Cloud unless a
     cloud_run_report issue says so. -->

## Notes for the reviewer
