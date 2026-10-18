# The application on the local platform

tx03v2 builds in Docker the complete platform that the v1 lab had only in cloud:
Istio, cert-manager, External Secrets, Prometheus/Alertmanager/Grafana, Loki/Alloy,
Tempo and OpenTelemetry Collector, Argo CD, Gatekeeper, Trivy Operator, Velero and
Chaos Mesh. It runs on kind with emulated Artifact Registry, Cloud SQL, Cloud
Storage (through an S3 API emulator), load balancer and Git server (tx03v2's
`docs/LOCAL_LAB.md`). This repository deploys the application through GitOps and
proves its behavior with probes. Nothing here contacts Google Cloud.

Status: `verified in CI` (`e2e-platform` at default size and
`e2e-platform-small` with Docker limited to 7 GB). R7.2 added the rollback
exercise to the historical 18-probe suite; later rounds add continuity/capacity
checks. The script's current probe list is authoritative. `verified locally`
on 2026-10-13 means the then-current 13 probes, a fresh
tx03v2 local platform, destroyed without leftovers. The five 2026-10-14 probes
(traces, rollout and database chaos) ran only in CI: the default full platform
plus app exceeds the development Docker Desktop's 7.65 GiB. The `small` size fits
within 7 GB (below).

## Run it

```bash
make build                         # dx03v2-api:e2e and dx03v2-web:e2e, or let the e2e build them
make e2e-platform                  # create tx03v2 lab, deploy, probe, destroy everything
LOCAL_SIZE=small make e2e-platform # same platform at small size (7 GB Docker)
```

The script clones tx03v2 at `deploy/local/tx03v2.ref`. `TX03V2_DIR=<checkout>`
uses an existing checkout; `TX03V2_REPO=<https URL>` clones another repository
(your fork; in CI, repository variable `TX03V2_REPO`, see `FORK.md`).
`KEEP_LAB=1` retains the lab afterward (then run
`bash <tx03v2>/scripts/local-lab.sh down`). Inside a container using the host's
Docker, export `LOCAL_KIND_INTERNAL=1`. Docker needs 8 GB, or 7 GB with
`LOCAL_SIZE=small`.

With the tx03v2 lab already running (`make local-up` there), deploy alone:

The reference integrates the merged [tx03v2#18 readiness fixes](https://github.com/maringelix/tx03v2/pull/18),
including bounded OpenCost convergence polling. Positive measured allocation
remains mandatory. The reference also integrates [tx03v2#19 English documentation](https://github.com/maringelix/tx03v2/pull/19)
at the actual main merge `669911716eaec1866fb9bb8d831ab5b32e5d33ed`.
Full/small jobs use that same pinned source. Local evidence does not
validate managed IAM, admission or DR.

```bash
export KUBECONFIG="$(bash ../tx03v2/scripts/local-lab.sh kubeconfig)"
GIT_SHA=$(git rev-parse HEAD) scripts/deploy-local.sh
```

`scripts/deploy-local.sh` rejects any kubectl context other than
`kind-tx03v2-local`: it never deploys to another currently selected cluster.

## The small size and the 7 GB evidence

`LOCAL_SIZE=small` reaches tx03v2's `platform/local/install.sh`: the same
components, with lower memory limits, short Prometheus/Tempo retention, fewer
series and workers (tx03v2's `docs/LOCAL_LAB.md` lists each chart's changes).
The application is unchanged. Values other than `default` or `small` fail before
any build.

`make e2e-platform-small` (CI job `e2e-platform-small`,
`scripts/e2e-platform-small.sh`) runs `e2e-platform` with `LOCAL_SIZE=small`
inside digest-pinned Docker-in-Docker (`docker:29.9.0-dind`), limited to 7 GB
without swap: the equivalent of a laptop allocating 7 GB to Docker. The job
result is the e2e result. Its summary includes peak memory of the whole daemon,
peak anonymous memory (page cache fills any limit; without swap, anonymous memory
cannot be reclaimed), largest containers and processes killed by the kernel for
lack of memory. It is not a ruleset-required check: default-size `e2e-platform`
gates the merge.

| Full platform + app | Docker | Result |
|---|---|---|
| Default size | CI runner, 16 GB | Passes (`e2e-platform`) |
| Small size | 7 GB, no swap (CI, 2026-10-15) | Historical 18 probes before rollback passed in about 13 minutes, 4.40 GiB anonymous memory. In one of two runs, the kernel twice killed the Velero plugin copy (BestEffort init container, retried by kubelet). Later CI repeats the expanded suite. |

Pair 01 also measured default size at 7 GB (thrashing failure), small at 6 GB
(the rollout probe loses requests), and small at 8 GB (passes): see dx01v2's
`docs/LOCAL_LAB.md`. R1.8 targeted 6 GB; Bruno selected 7 GB for small on
2026-10-15, below the development Docker Desktop's 7.65 GiB. Largest working-set
peaks in the 2026-10-15 job: Kubernetes apiserver 1279 MiB, Grafana 309 MiB,
Argo CD controller 284 MiB, Prometheus 250 MiB, Trivy Operator 190 MiB, etcd
160 MiB, both Gatekeeper Pods 264 MiB, API 62 MiB per pod.

`e2e-platform-small` is heavy: besides its 7 GB, the inner daemon downloads every
lab image again. It is intended for the CI runner; on a 16 GB laptop with editor
and browser open, run `LOCAL_SIZE=small make e2e-platform` with Docker set to 7 GB.

## Deployment flow (`scripts/deploy-local.sh`)

1. Read local contract `lab-system/lab-contract` (version 2) and reject values
   that differ from the overlay's pinned registry, secrets, ClusterSecretStore,
   GatewayClass, issuer, AppProject and OTLP endpoint.
2. Push images to the lab registry (local Artifact Registry twin), using the commit tag:
   `localhost:5003/dx03v2/*:<sha>`; inside the cluster,
   `registry.tx03v2.local/dx03v2/*`.
3. Copy the lab CA to namespace ConfigMap `lab-ca`
   (the API uses `DB_SSL_MODE=verify-full`).
4. Render `deploy/k8s/overlays/local-platform` from the contract and commit it
   to the lab Git server's GitOps repository, pushing with
   `lab-secrets/gitops-push-key`.
5. Create Application `dx03v2` (AppProject `dx03v2`, prune and self-heal), wait
   for Synced/Healthy at the newly pushed commit (redeployment may still report
   Synced for the previous commit), rollouts and Gateway `Programmed`.

The overlay adds to `base`: Gateway `dx03v2` (class `istio`, HTTPS with a
`lab-ca` certificate, HTTP → 301) and HTTPRoutes (`/api` → api:3000,
`/` → web:8080, the same routing as GKE Gateway); ExternalSecrets from `local-secrets`
(the local Secret Manager twin); HPA 2–4; `PeerAuthentication` `STRICT` and identity
`AuthorizationPolicy` (Gateway/web to API, Gateway to web, Prometheus to metrics);
NetworkPolicies with HBONE (15008) and ambient kubelet probes
(`169.254.7.127/32`); API egress only to the database (`10.252.0.11/32`) and
OpenTelemetry Collector (OTLP/HTTP, `OTEL_EXPORTER_OTLP_ENDPOINT`); Gateway
egress to Collector (its spans, OTLP/gRPC), both through mesh HBONE;
ServiceMonitor, five alert rules and a Grafana dashboard. It uses only kinds
allowed by tx03v2's `dx03v2` AppProject (checked by `contract-app`).

R8.2 `mesh-full` adds waypoint Gateway `dx03v2-waypoint`, class `istio-waypoint`,
attached only to the three mesh-* Services. Two backends use the API image
(`mesh-stable`, `mesh-canary`, api/src/mesh-demo.ts); HTTPRoute splits /variant
80/20 and bounds /fail retries at two (TX local experimental Gateway API).
DestinationRule ejects the canary after three 5xx; waypoint AuthorizationPolicy
accepts only mesh-probe. Explicit policies allow HBONE15008,istiod15012 and
kubelet probes. Other app traffic bypasses the waypoint. Cloud runs the same
exercise in managed Cloud Service Mesh sidecars (`mesh-csm`).

## Connected traces, logs and metrics

The API creates a SERVER span per request (route name, never the raw path) and a
CLIENT span per PostgreSQL query inside it (parameterized SQL only; values never
enter spans). It continues the W3C `traceparent` sent by the Istio Gateway. Spans
travel through OTLP/HTTP to tx03v2's Collector, which writes to Tempo. Each log
line inside a request includes `trace_id`/`span_id`; the latency histogram stores
`trace_id` as an exemplar (`/metrics` uses OpenMetrics). In Grafana, follow the
latency chart to a trace, the trace to logs, and a log line back to its trace.
Without `OTEL_EXPORTER_OTLP_ENDPOINT` (Compose, kind, tests), nothing is exported.

## What the probes prove (`scripts/e2e-platform.sh`)

| Probe | Evidence |
|---|---|
| gitops | Images exist in the lab registry, Argo CD synchronized the commit (Synced/Healthy), and recreates a deleted object |
| backup | `pg_dump` of the lab database, deletion through API, restore recovers the message |
| smoke | Complete `e2e/smoke.mjs` with `SMOKE_EDGE=istio` over HTTPS at `dx03v2.tx03v2.local` outside the mesh: emulated load balancer → Istio Gateway → app, certificate checked against lab CA |
| mesh | Outside plaintext client cannot reach API or demo; mesh-probe measures 80/20 across 400 requests, initial request plus two retries counted in backend logs, then no canary traffic after ejection; mesh-intruder receives403 |
| observability | Prometheus scrapes API through mesh, five rules are loaded, smoke traffic metrics exist, Grafana loaded its dashboard, API logs reached Loki |
| tracing | A read with `traceparent` appears in Tempo from edge to database (Gateway span, `GET /api/messages`, `SELECT dx03v2`); its Loki logs contain `trace_id` and Prometheus has a matching exemplar |
| trivy | Trivy Operator generated vulnerability reports for app images |
| hpa | HPA reports `ScalingActive` (metrics-server) |
| rollout | Hypothesis: a new version delivered through GitOps (new tags, `maxUnavailable: 0`, readiness, `preStop` and graceful shutdown) loses no request from a reader alternating API and web through the Gateway (zero downtime) |
| chaos | Hypotheses: with two replicas, killing an API Pod preserves reads (at least 38/40); adding 200 ms between API and PostgreSQL (`NetworkChaos`) preserves every read and shows the delay in its query span |

`SMOKE_EDGE=istio` routes `/api` directly to API like GKE Gateway (the API's own CSP,
one proxy hop: `TRUST_PROXY_HOPS=1`, versus two behind Google's load balancer).
Like nginx, a safe external `X-Request-Id` returns unchanged through the
gateway-preserve-request-id EnvoyFilter. Google's behavior is undocumented;
SMOKE_EDGE=gke checks only its safety. `promtool` also tests rules without a cluster
(`promtool-rules`, `deploy/k8s/components/local-platform/alerts-test.yaml`).

## Limits

- The historical default scenario runs on one kind node. None of it proves GKE Autopilot,
  GKE Gateway/WAF, Secret Manager, Workload Identity Federation for GKE or Cloud SQL behavior; Google Cloud
  deployment remains `not run in the cloud (v2)`. R10's HA topology is a separate
  capacity exercise, documented in `FINOPS.md`.
- Autopilot would reject privileged local ambient/Chaos components. Its request
  minima/CPU:memory ratios are structurally checked in gcp overlays by contract-app,
  not enforced by kind. Managed Cloud SQL uses PSC, unlike the local database.
- The API sees the emulated load balancer's address as its client (its Envoy uses
  TCP): rate limiting aggregates all clients in the local lab.
- The deployment creates `lab-ca` outside GitOps (like Google Cloud's `cloudsql-ca`).
- Rollout changes only image tags, keeping content identical: it proves delivery
  and Pod replacement, not an incompatible database migration.
