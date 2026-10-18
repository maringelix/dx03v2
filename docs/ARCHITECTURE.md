# dx03v2 architecture

How the app fits together in each environment (Compose, kind, GKE Autopilot),
design decisions, differences from the AWS (`dx01v2`) and Azure (`dx02v2`) pairs,
and changes from Google Cloud v1 (`dx03`). The infrastructure contract is in
`docs/CONTRACT.md`; endpoints are in `docs/API.md`.

## The app comes from dx01v2

By project decision (2026-10-11), each cloud pair has its own application
repository, but all three run the **same** app for a fair comparison. `dx02v2`
began as a copy of every tracked file in `dx01v2` commit `22e69c4`
(maringelix/dx01v2). This repository began as a copy of every tracked dx02v2 file,
with names replaced (`dx02v2` → `dx03v2`, `tx02v2` → `tx03v2`). Only the deployment
target changed: tx03v2 GKE Autopilot instead of tx02v2 AKS. API, page, migrations,
tests, smoke test, manifest `base` and `local` kind overlay behave identically.
Differences appear in the comparison table below. `docs/MAINTENANCE.md` defines
the quarterly routine: compare `api/`, `web/` and `e2e/` with both siblings and
port fixes.

## Components

| Component | Purpose | Image (by digest) |
|---|---|---|
| `api` | Express 5 + strict TypeScript (ESM) on Node.js 24: message board, probes, separate metrics port | build `node:24-alpine3.24`; runtime `gcr.io/distroless/nodejs24-debian13:nonroot` (uid 65532, no shell/npm) |
| `migrate` | `dist/migrate.js` in the same API image: applies `api/migrations/*.sql` under an advisory lock | API image |
| `web` | React 19 page (Vite 8) served by nginx, which also proxies `/api/` | build `node:24-alpine3.24`; runtime `nginxinc/nginx-unprivileged:1.30-alpine-slim` (uid 101, port 8080; no image-filter/xslt/geoip/njs modules) |
| database | PostgreSQL 17 | local/kind: `postgres:17-alpine`; Google Cloud: tx03v2 Cloud SQL for PostgreSQL 17, Private Service Connect only |

## Local (Compose, project `dx03v2-dev`)

```mermaid
flowchart LR
  user((Browser)) -->|"127.0.0.1:8080"| web
  subgraph compose["project dx03v2-dev"]
    subgraph frontend["frontend network"]
      web["web (nginx-unprivileged)"]
    end
    api["api (TRUST_PROXY_HOPS=1)"]
    subgraph backend["backend network"]
      db[("db: postgres:17-alpine<br/>volume db-data")]
      migrate["migrate (dist/migrate.js)"]
    end
    web -->|"/api/ → api:3000"| api
    api --> db
    migrate --> db
  end
```

`db` (healthcheck) → `migrate` (successful exit) → `api` (healthy `/readyz`) → `web`.
Only web is published, on 127.0.0.1. All use a read-only root filesystem,
`cap_drop: [ALL]` and `no-new-privileges`; secrets come from the `.env` generated
by `scripts/dev-env.sh`.

## kind (`make e2e`)

```mermaid
flowchart LR
  smoke["e2e/smoke.mjs"] -->|"kubectl port-forward svc/web"| web
  subgraph ns["namespace dx03v2: Pod Security restricted, default deny"]
    web["Deployment web ×2"] -->|"web → api:3000"| api["Deployment api ×2<br/>initContainer migrate"]
    api -->|"api → postgres:5432"| pg[("StatefulSet postgres<br/>emptyDir, uid 70")]
    probe["probe pods"] -.->|"blocked"| api
    probe -.->|"blocked"| pg
  end
```

One Kubernetes 1.36 node (`kind/kind-config.yaml`); images loaded with `kind load`
and `imagePullPolicy: Never`; random Secrets created by the script. kindnet,
kind's default CNI, enforces NetworkPolicy since kind v0.24.0
(kube-network-policies); E2E proves allowed and blocked paths.

## Google Cloud (tx03v2 GKE Autopilot, `not run in the cloud (v2)`)

```mermaid
flowchart LR
  internet((Internet)) --> lb["Global external Application Load Balancer<br/>tx03v2-lab-gateway address + Cloud Armor (tx03v2)"]
  subgraph gke["GKE Autopilot tx03v2-lab (Dataplane V2), namespace dx03v2"]
    gw["Gateway dx03v2 + HTTPRoute<br/>(GKE Gateway controller)"]
    lb -->|"/api → api:3000, zonal NEG directly to pod"| api["api ×2–4 (HPA, CPU 70%)"]
    lb -->|"/ → web:8080"| web["web ×2"]
    web --> api
    eso["ExternalSecrets"] -->|"db-credentials, app-secrets"| api
  end
  gw -.->|"programs"| lb
  api -->|"TLS verify-full (ConfigMap cloudsql-ca)<br/>PSC endpoint /32"| sql[("Cloud SQL PostgreSQL 17")]
  sm["Secret Manager"] --> eso
  gha["deploy-gcp (Workload Identity Federation, workflow_dispatch)"] -->|"Parameter Manager, Artifact Registry + promotion attestation, GitOps or direct apply"| gke
```

tx03v2 owns the namespace, deployer RBAC, ClusterSecretStore, External Secrets
Operator, reserved global address, Cloud Armor policy, Secret Manager, Artifact
Registry and Cloud SQL (including PSC endpoint and private DNS zone). Google
manages the Gateway controller. The app supplies Gateway, HTTPRoute,
HealthCheckPolicies, optional GCPBackendPolicies, ExternalSecrets, HPA and
NetworkPolicies. Contract values (images, address name, Cloud Armor policy,
load-balancer ranges and Cloud SQL endpoint IP) enter through `params.env` and
kustomize `replacements`. The load balancer reaches pod IP/ports directly through
zonal NEGs, from Google Front End/health-check ranges `35.191.0.0/16` and
`130.211.0.0/22`; NetworkPolicies therefore allow those ranges rather than nodes.

`full` adds HTTPS on the contract hostname (managed certificate through tx03v2's
Certificate Map, HTTP 301 redirect) and a managed Cloud Service Mesh sidecar
exercise: a `VirtualService` splits `/variant` 80/20 across `mesh-stable` and
`mesh-canary`, bounds `/fail` retries, and a `DestinationRule` ejects the canary
after three 5xx responses. An `AuthorizationPolicy` accepts only identity
`mesh-probe`; `mesh-intruder` receives 403. Autopilot cannot run Istio ambient,
so the local lab proves this exercise in ambient (`components/mesh-full`, with
a waypoint) while the cloud uses sidecars (`components/mesh-csm`). Both share
backends in `components/mesh-demo`.

## Decisions

1. **One process per container.** Separate images/Deployments for API and web;
   no nginx/Node combination managed by a shell trap.
2. **Distroless API runtime.** `nodejs24-debian13:nonroot`, no shell/npm (the
   `debian12` variant stopped at Node.js 24.14.0). Compose healthchecks use one
   Node expression (`/nodejs/bin/node -e fetch(...)`).
3. **Owned nginx web configuration.** `default.conf` has `server_tokens off`,
   IPv4/IPv6, local `/healthz`, standard forwarding headers on `/api/`, SPA
   fallback and long caching for hashed assets. A security-header snippet is
   included in **every** `location`. HSTS applies only when `X-Forwarded-Proto`
   is `https`; the load balancer fills it with the received protocol. Core's
   HTTP-only listener therefore has no HSTS; full serves HTTPS and supplies `https`.
4. **`trust proxy` counts hops.** `TRUST_PROXY_HOPS=1` in Compose/kind (nginx)
   and `2` in Google Cloud. "External Application Load Balancer overview"
   (checked 2026-10-11) says the proxy appends `<client IP>,<load balancer IP>`
   to the supplied `X-Forwarded-For`; connections arrive from a Google Front End.
   With two trusted hops, `req.ip` is the client and fake entries on the left are
   ignored. The `rate-limit` integration test covers this format in all three
   repos; smoke proves 429 using a different fake `X-Forwarded-For` per request.
5. **In-memory write rate limit.** `express-rate-limit` by `req.ip`, default
   10/minute, counted before validation. N replicas permit up to N times that
   effective limit; shared Redis was excluded for cost/complexity.
6. **JSON errors and limits.** Every error uses
   `{"error":{"code","message","requestId"}}`; API bodies are limited to 10 kb
   (413), nginx to 64k; non-JSON receives 415, database outages receive
   503 `db_unavailable` without internals.
7. **Startup configuration validation.** zod validates the environment;
   `APP_ENV=lab` accepts only `DB_SSL_MODE=verify-full` with `DB_SSL_CA_FILE`.
   The environment label uses `APP_ENV`, never `NODE_ENV` (a v1 mistake).
8. **Recoverable database access.** Lazy `pg` pool (3 s connect,
   `statement_timeout` 5 s); `/readyz` runs `SELECT 1` with a 1 s bound and returns
   to 200 after database recovery.
9. **Explicit migrations.** Numbered SQL, one transaction per file,
   `pg_advisory_lock`, checksum in `schema_migrations`. Run in initContainer
   `migrate` and Compose service `migrate`.
10. **Graceful shutdown.** SIGTERM → `/readyz` 503 → `server.close()` →
    `pool.end()` → pending-span flush (at most 5 s; Collector outage does not fail
    shutdown); forced exit after `SHUTDOWN_TIMEOUT_MS` (10 s), `preStop` sleep 5 s.
11. **Separate metrics.** `/metrics` on 9464, OpenMetrics with request `trace_id`
    exemplars. Neither web nor Gateway exposes it; NetworkPolicy allows only
    namespace `monitoring`. The TX full/local platform supplies Prometheus.
12. **Gateway API through GKE's controller.** Google manages it (nothing to
    install/version). GKE serves Gateway API v1.5.0 (GKE >=1.35.2-gke.1842000,
    enabled by default on Autopilot). Class `gke-l7-global-external-managed`
    creates a global external Application Load Balancer. `spec.addresses` with
    `type: NamedAddress` uses the tx03v2 reservation, keeping the IP stable and
    avoiding v1's second public IP. HTTPRoute sends `/api` directly to API (longest
    path wins) and `/` to web. Each Service has a HealthCheckPolicy (`/healthz`
    8080, `/readyz` 3000), from the same ranges as traffic.
13. **Optional WAF component.** `components/gcp-waf` (one GCPBackendPolicy per
    Service with Cloud Armor `securityPolicy`) enters only `gcp-waf`/
    `gcp-waf-full`, selected when `waf/security-policy` differs from `none`.
    With `none`, `gcp`/`gcp-full` deletes old policies that would reference a
    removed Cloud Armor policy.
14. **Kustomize components.** Neutral `base`; `overlays/local` (kind), `gcp` and
    `gcp-waf` (core), `gcp-full`/`gcp-waf-full` (core + `gcp-https`/`mesh-csm`),
    and `local-platform` (tx03v2 kind ambient mesh). Cloud HPA owns API replicas
    (`spec.replicas` removed). CI renders/validates every overlay using
    `params.example.env`.
15. **Generated, pinned CRD schemas.** kubeconform validates Gateway/HTTPRoute
    against schemas converted by `scripts/update-crd-schemas.sh` from official
    Gateway API v1.5.0 `standard-install.yaml` (SHA256 matches GitHub's digest),
    the GKE-served version. GKE installs `networking.gke.io` itself and Google
    publishes no CRD file, so HealthCheckPolicy/GCPBackendPolicy schemas come
    from pinned datreeio/CRDs-catalog commit `f3e4382` with SHA256 checks.
    ExternalSecret still uses the harness's pinned catalog.
16. **Pod security.** Pod Security `restricted` everywhere, no service-account
    token, default-deny NetworkPolicies with only necessary allows. Autopilot
    increases requests below its minimum (50m CPU and 52 MiB per general-purpose
    pod, "Resource requests in Autopilot", checked 2026-10-12). The `gcp` web
    overlay requests 64Mi so the manifest matches runtime.
17. **Immutable image tags.** Artifact Registry uses the full commit SHA in an
    immutable-tag repository. Deploy lists tags and reuses an existing image
    rather than republishing. Local tags are `e2e` (kind)/`local` (Compose).
    Attested promotion without rebuilding: `deploy-gcp` verifies release/GHCR
    images, promotes identical digests and signs an attestation linking source
    and destination; full Kyverno requires that signature before pod admission.
    `platform_profile=core|full`; `deploy_mode=auto|gitops|push`.
18. **One credential source: gcloud.** In Actions, `google-github-actions/auth`
    writes WIF credentials (`gha-creds-*.json`, excluded from Git and every build
    context, enforced by `policy-images`) renewed by gcloud during the job.
    kubectl gets tokens through `gke-gcloud-auth-plugin`; registry authentication
    receives an access token on stdin. Deploy reads the contract, gets kubeconfig,
    checks RBAC and registry readiness before promotion/apply, failing early if
    the platform is not ready. Current cloud deployment consumes a verified
    release bundle; it does not build images.
19. **DNS control-plane endpoint.** No public IP endpoint; deployment uses
    `get-credentials --dns-endpoint` (`*.gke.goog`). IAM authenticates/authorizes
    each request (`roles/container.clusterViewer` in the contract); runners need
    no IP allowlist.
20. **Verified database TLS root.** Deploy downloads the regional public bundle,
    requires exactly one self-signed root with the contract SHA256 and only CAs
    issued by it (`openssl verify -x509_strict`, without system trust), then
    creates `cloudsql-ca` from rewritten certificates. The bundle is not pinned
    because subordinate CAs rotate. `verify-full` checks chain and instance DNS
    hostname (`host` in the secret).
21. **Address-based NetworkPolicies.** Ingress only from the two fixed load-balancer
    ranges, one `ipBlock` per range without `except`. API egress only to the
    Cloud SQL PSC `/32` on 5432, verified inside the node subnet; DNS through
    node cache `169.254.20.10`. "Setting up NodeLocal DNSCache" says this rule is
    unnecessary with Cloud DNS/Dataplane V2 (both always enabled on Autopilot),
    but it remains explicit and opens only port 53 at that address.
22. **One smoke test for every environment.** Plain Node `e2e/smoke.mjs` runs
    against Compose, kind and load balancer with edge-specific assertions.
    `SMOKE_EDGE=nginx` (default) expects web CSP on `/api` and echoed
    `X-Request-Id`; `SMOKE_EDGE=gke` expects API CSP and only the security property
    of `X-Request-Id` (load-balancer docs do not specify forwarding/replacement/
    addition). A 70 KB body receives 413 from nginx (64k) or the API behind
    Gateway (Cloud Armor inspects the first 64 KB without size blocking).
23. **OpenTelemetry traces without a loader.** The API creates SERVER spans per
    request and CLIENT spans per query with official OpenTelemetry API/SDK,
    avoiding ESM auto-instrumentation's module-loader hook. OTLP/HTTP spans go
    to tx03v2's Collector (`OTEL_EXPORTER_OTLP_ENDPOINT`, disabled when absent),
    then Cloud Trace. W3C context, log `trace_id`/`span_id` and exemplars correlate
    signals. `/healthz` and `/readyz` produce no spans. Same code in all DX repos.

### Known Google Cloud path risks

- **Keep-alive.** API idle connections close after 65 s (`keepAliveTimeout`,
  selected for nginx's 60 s). `api/src/server.ts` references this section; DX02's
  counterpart covers AGC. "Request distribution for external Application Load
  Balancers" (read 2026-10-12) documents a fixed 600 s backend keep-alive timeout.
  Earlier backend closure can cause occasional 502
  (`backend_connection_closed_before_data_sent_to_client`). Check the first
  cloud run; raising `keepAliveTimeout` above 600 s changes shared app behavior
  and must be coordinated across all three repos.
- **Cloud Armor preconfigured rules.** Smoke writes `<b>` text; sensitivity-1
  `xss-v33-stable` should accept it, but only a real run proves that (`deny(403)`).
- **Policy status/propagation.** Deploy waits for Gateway `Programmed` and the
  contract address, recording HTTPRoute/policy conditions without requiring a
  particular condition type (undocumented `networking.gke.io` status semantics).
  The load balancer can take minutes after `Programmed`; smoke waits up to 15 min.
- **GKE CRD RBAC.** Role plurals `healthcheckpolicies`/`gcpbackendpolicies` were
  inferred from catalog CRDs; `kubectl auth can-i` preflight catches divergence
  before writes.

## dx01v2 ↔ dx02v2 ↔ dx03v2

| Aspect | dx01v2 (AWS) | dx02v2 (Azure) | dx03v2 (Google Cloud) |
|---|---|---|---|
| App (`api/`, `web/`, migrations) | commit `22e69c4` + OpenTelemetry traces (2026-10-14) | same; names/comments only | same; names/comments only (span service `dx03v2-api`) |
| Traces | tx01v2 Collector → AWS X-Ray | tx02v2 Collector → Application Insights | tx03v2 Collector → Cloud Trace (Collector ServiceAccount is the IAM principal) |
| Tests | `22e69c4` suite + AGC no-space `X-Forwarded-For` and Google `<client>,<load balancer>` integration cases, `TRUST_PROXY_HOPS=2` | same suite | same suite (cases originated in DX02/DX03 and were ported to all three) |
| Smoke | `SMOKE_BEHIND_WAF=1`: WAF 403 above 8 KB | `SMOKE_EDGE=agc`: API CSP, AGC `X-Request-Id`, API 413 | `SMOKE_EDGE=gke`: API CSP, `X-Request-Id` security property, API 413 |
| Cluster | EKS 1.36, access entries | AKS 1.36, Entra ID, `kubelogin` | GKE Autopilot 1.36, REGULAR, DNS endpoint, `gke-gcloud-auth-plugin` |
| Ingress | AWS Load Balancer Controller ALB Ingress + WAFv2 | AGC Gateway API + WebApplicationFirewallPolicy | GKE Gateway API, global external Application Load Balancer + Cloud Armor GCPBackendPolicies |
| Trusted hops (`TRUST_PROXY_HOPS`) | 1 | 1 | 2 |
| Health checks | Service annotations | HealthCheckPolicy per Service | `networking.gke.io` HealthCheckPolicy per Service |
| Secrets | Secrets Manager → ESO | Key Vault → ESO | Secret Manager → ESO (`gcp-secret-manager`) |
| Contract parameters | SSM `/tx01v2/lab/*` | App Configuration `tx02v2/lab/*` | Parameter Manager `tx03v2-lab-contract`, JSON with 18 keys |
| Registry | ECR, IMMUTABLE tags | ACR, deployment refuses tag overwrite | Artifact Registry immutable tags, existing tag reused |
| Database TLS | regional `rds-ca` bundle | three roots with verified SHA1 thumbprints | regional bundle with contract SHA256 root and its issued CAs only |
| Edge NetworkPolicies | VPC CIDR (ALB/RDS) | AGC /24 subnet and delegated PostgreSQL subnet | load-balancer ranges, PSC /32, node DNS cache |
| NetworkPolicy enforcement | VPC CNI | Cilium (Azure CNI Overlay) | Dataplane V2 |
| HTTPS | `aws-https` (ACM certificate) | AGC ACME certificate in full | Gateway managed Certificate Map in full (`gcp-https`) |
| GitHub identity | IAM role with OIDC | managed identity, federated credential | `dx03v2-gha-deploy` service account, WIF |
| Harness tools | 8 | same + `kubelogin` | same 8; workflow `setup-gcloud` provides gcloud |
| kubeconform schemas | datreeio catalog (ESO) | plus generated ALB Controller CRDs | plus official Gateway API asset and pinned catalog `networking.gke.io` |

## v1 → v2

Google Cloud v1 problems (`dx03`, tx03v2 `docs/LESSONS_LEARNED.md` lessons 18 and
30–37) that v2 must not repeat. General v1 lessons (fixed CORS, all-500 errors,
wrong probes, `expect(true).toBe(true)`, HSTS on HTTP, UTF-16) are in the DX01/DX02
tables and remain covered here by the same checks.

| v1 problem | v2 solution | Verification |
|---|---|---|
| Client `npm ci` ERESOLVE (eslint 8/plugin requiring 9), after EUSAGE without lockfile and `.gitignore` hiding `package.json` | one root workspace lockfile, exact versions, strict `npm ci` including Dockerfiles | `npm-ci`, `version-consistency`, `image:*` |
| ConfigMap `NODE_ENV: "dev"` crashes backend (`Invalid NODE_ENV`) just to change a UI label | `APP_ENV` label (`lab` in `gcp`), zod validates startup with readable errors | `config` tests, `contract-app` |
| Readiness uses `Authorization: Bearer METRICS_TOKEN_PLACEHOLDER`, needs deploy `sed` | public `/healthz`/`/readyz`, contract-checked policies/probes, admin token only from `app-secrets` ExternalSecret | `readiness` tests, `contract-app` |
| UI reads removed `/health` fields, production TypeError | API/page change together, page/integration tests and same smoke across Compose/kind/LB (cloud unrun) | `test:web`, `test:api`, smoke |
| Mutable `:latest`/floating base images | full 40-character SHA immutable tags; digest-pinned bases; no `:latest` | `policy-images`, `contract-app` (no latest/docker push in deploy) |
| Database password/host in GitHub secrets, workflow creates Secret | ESO from Secret Manager; deploy has no Secret Manager rights and never writes Secrets | `contract-app` (Role types, no Secret), `policy-workflows` |
| Argo CD syncs nonexistent path, app workflow also owns namespace | workflow configures overlay/GitOps branch, publishes revision, waits for Argo; parent ignores only dynamic Application fields | `contract-app` patches; cloud sync unrun |
| Hand-created WIF open to entire owner; extra hand-made DX binding after failure | TX Terraform pool/provider restricted to both repos, exact immutable environment subject per service account; no service-account keys or credentials in Git/images | `policy-workflows`, `policy-images` |
| API URL resolved at build, public IP in comment | same origin, `/api` and `/` on one HTTPRoute; only documented placeholders/ranges | `policy-identifiers`, `contract-app` |
| Status precedes evidence ("PRODUCTION READY", "100% HEALTHY") | status/evidence matrix; no Google Cloud claim without `cloud_run_report` | `repo-structure`, review |
