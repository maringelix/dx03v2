# Security policy

## Reporting a vulnerability

Report privately through GitHub: **Security > Report a vulnerability** on this repository (private
vulnerability reporting is enabled when the repository is public, see `docs/PUBLICACAO.md`). Do not
open a public issue. Never include credentials, admin tokens, project IDs or numbers, service account
e-mails or IP addresses; use placeholders.

This is a personal educational project: reports are handled on a best-effort basis, with no response
time guarantee and no bug bounty.

## Supported versions

Only the latest commit on `main`. There are no releases yet.

## What this repository does to stay safe

The rules, where each one is enforced and the known limits are in
[docs/GUARDRAILS.md](docs/GUARDRAILS.md). In short:

- The harness (`make verify`, `make build`, `make e2e`, also the CI) runs gitleaks, eslint with
  type-aware rules, hadolint, actionlint, shellcheck, kubeconform (with the Gateway API schemas of
  the version GKE serves and the `networking.gke.io` schemas, both pinned by SHA-256), trivy (config
  and images, HIGH/CRITICAL with a fix available) and policy checks that block real identifiers,
  public addresses other than the load balancer ranges of the contract, unpinned actions and images,
  service account keys and the regressions found in v1.
- API: input validated with zod (control characters rejected, text stored as received and rendered
  as text by the UI), JSON errors without internals, `trust proxy` as a hop count so spoofed
  `X-Forwarded-For` entries cannot bypass the per-client write rate limit (tested, including the
  `<client-ip>,<lb-ip>` format of the Google Cloud load balancer with two trusted hops), admin token
  compared in constant time and never logged, credentials redacted from logs.
- Web: strict Content-Security-Policy without inline scripts or styles, security headers on every
  response including static assets, HSTS only for requests that arrived over HTTPS (the Gateway has
  no HTTPS listener yet, so no HSTS is sent there).
- Containers run as numeric non-root users with a read-only root filesystem; the API runtime image
  is distroless (no shell, no npm). Kubernetes: Pod Security `restricted`, default-deny
  NetworkPolicies (enforcement proven on kind), no service account tokens; on Google Cloud the pods
  accept traffic only from the load balancer ranges and the API reaches only the Cloud SQL endpoint.
- GitHub Actions reach Google Cloud only through Workload Identity Federation with the service
  account `dx03v2-gha-deploy` (one exact subject: the environment `lab`); there are no service
  account keys, and the credentials file of `google-github-actions/auth` is kept out of git and of
  every image build context (checked). Runtime secrets come from Secret Manager through External
  Secrets; the deploy identity cannot read them in Secret Manager. The deploy trusts only the Cloud
  SQL root of the contract (SHA-256) and the CAs it issued, and never pushes over an existing image
  tag (the Artifact Registry repository has immutable tags).
- Every harness tool is pinned by version and SHA256; actions by commit SHA; images by digest; npm
  dependencies by exact version and a committed lockfile; gcloud by version.

## Known limits

The Google Cloud deploy has never run (`not run in the cloud (v2)`); it was exercised offline with
stub CLIs only. The admin token is a single shared bearer token (no users, no rotation automation).
The write rate limit is kept in memory per API replica, so the effective limit grows with the number
of replicas. The smoke test reads the admin token from the Secret `app-secrets`, so whoever can
dispatch the deploy can see it. The kind e2e proves NetworkPolicy enforcement with kindnet, not with
GKE Dataplane V2. There is no HTTPS yet. See the "Limites" section of docs/GUARDRAILS.md.
