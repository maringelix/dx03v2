# tx03v2 <-> dx03v2 contract — version 5 (2026-10-17)

Version 5 (R9) keeps the 18 keys and adds independent contract
`tx03v2-lab-dr-contract`. `LAB_TARGET=primary|secondary` selects only one of the
two IaC-created runtimes. The secondary has its own cluster, VPC, PSC, registry
and `tx03v2-lab-dr-*` secrets; manifests and Argo CD overrides receive those names.
Branches `gitops/gcp` and `gitops/gcp-dr` are independent: a DR deploy does not
redirect primary reconciliation. TLS map and WAF are project-global resources.
Deployment neither promotes the database nor changes DNS automatically.

Version 4 (R8): three new parameter keys (`dns/hostname`, `dns/certificate-map`,
`mesh/management`), managed-certificate HTTPS/HTTP redirect in `full`, managed
Cloud Service Mesh (sidecars only in the app namespace), and the promotion
attestation required by Kyverno admission. Version 3: `full` registers Argo CD
Application `dx03v2` tracking `gitops/gcp`; deploy identity can refresh only that
Application. Version 2 (2026-10-14) added the platform OpenTelemetry Collector
(`observability`, traces to Cloud Trace). Version 1 (2026-10-11) had no traces.

Interface between infrastructure (`tx03v2`) and this application, covering the
parts consumed by the app. The source of truth is
[tx03v2 `docs/CONTRACT.md`](https://github.com/maringelix/tx03v2/blob/main/docs/CONTRACT.md);
that file wins on divergence. Every change requires coordinated PRs in both
repositories and a version increment.

## How this repository verifies the contract

| What | Where | Status |
| --- | --- | --- |
| Service names, ports, probes, Secrets, ConfigMap, Gateway (class/NamedAddress/listener), HTTPRoute paths, HealthCheckPolicies, GCPBackendPolicies, ExternalSecrets, HPA, NetworkPolicies (LB ranges, Cloud SQL /32, node DNS cache), `TRUST_PROXY_HOPS=2`, labels, full Istio VirtualService/DestinationRule/AuthorizationPolicy, only kinds writable by `dx03v2-deployer` | `contract-app`, `scripts/check-manifests.mjs` on rendered `gcp`, `gcp-waf`, `gcp-full`, `gcp-waf-full`, `local-platform` | `verified locally` |
| Version 2 OTLP endpoint in API ConfigMap and egress only to Collector (`observability`, 4318) | `contract-app` | `verified locally` |
| Valid Kubernetes 1.36, Gateway API v1.5.0 standard, `networking.gke.io/v1` HealthCheckPolicy/GCPBackendPolicy and `external-secrets.io/v1` ExternalSecret | `crd-schemas`, strict `kubeconform` | `verified locally` |
| Overlay parameter formats: Artifact Registry images/full 40-character SHA, address name, Cloud Armor policy or none, exact two LB ranges, RFC1918 Cloud SQL endpoint; invalid/unknown/missing values rejected | `k8s_validate_params`, `scripts/lib/k8s.sh`, exercised by `contract-app` (10 invalid inputs rejected) | `verified locally` |
| Deploy reads exactly the 18 keys below, verifies fixed values against manifests, trusts only contract Cloud SQL root, chooses `gcp-waf`/`gcp` (`-full` when `PLATFORM_PROFILE=full`), uses DNS endpoint and read-only gcloud discovery | `contract-app` on `scripts/deploy-gcp.sh` | `verified locally` |
| Real-cluster values: project equals `GCP_PROJECT_ID`, repository `<region>-docker.pkg.dev/<project>/dx03v2`, database IP inside node subnet, API-group/RBAC preflight, Gateway at contract address | `scripts/deploy-gcp.sh` fails before promotion/apply (offline simulated CLIs, `docs/HARNESS.md`) | `not run in the cloud (v2)` |
| Actual Google Cloud behavior | `docs/RUNBOOK.md` | `not run in the cloud (v2)` |

## Identifiers

| Item | Value |
| --- | --- |
| Google Cloud project | dedicated lab project, GitHub variable `GCP_PROJECT_ID`; examples `tx03v2-lab-example`, number `000000000000` |
| Region | tx03v2 `region`, default `us-central1` (key below) |
| Project/environment/prefix | `tx03v2` / `lab` / `tx03v2-lab` |
| GKE cluster | `tx03v2-lab`, regional Autopilot, `REGULAR` (Kubernetes 1.36), private nodes, public IP endpoint disabled, IAM-only authorized DNS endpoint, standard Gateway API, Dataplane V2 enforcing NetworkPolicy |
| Nodes | x86-64, Autopilot general-purpose; images `linux/amd64` |
| App namespace | `dx03v2`, created by TX platform with `pod-security.kubernetes.io/enforce=restricted`, `pod-security.kubernetes.io/enforce-version=latest`; `gcp*` overlays do not create it, `local` creates an equivalent for kind |
| Deployer Kubernetes RBAC | Role `dx03v2-deployer`, RoleBinding `dx03v2-deployers` in `dx03v2`; `kind: User` subjects for `dx03v2-gha-deploy` service-account email and tx03v2 `app_deployer_members` emails |
| Artifact Registry | regional Docker repository `dx03v2`, immutable tags; `<region>-docker.pkg.dev/<project_id>/dx03v2/api` and `.../web`, tag full 40-character DX git SHA; node service account reads it |
| Deploy service account | `dx03v2-gha-deploy@<project_id>.iam.gserviceaccount.com`, example `dx03v2-gha-deploy@tx03v2-lab-example.iam.gserviceaccount.com` |
| Traces (OpenTelemetry, version 2) | `http://opentelemetry-collector.observability.svc:4318`, OTLP/HTTP `OTEL_EXPORTER_OTLP_ENDPOINT` in `gcp`; TX installs Collector, whose ServiceAccount has `roles/cloudtrace.agent`; app receives no IAM role for traces |

Role `dx03v2-deployer` in namespace `dx03v2` limits kinds in `gcp*` overlays.
`contract-app` rejects other kinds; deployment checks each verb with
`kubectl auth can-i` before promotion/apply:

- `apps`: deployments → get/list/watch/create/update/patch/delete;
  replicasets → get/list/watch.
- core: services/configmaps/serviceaccounts → get/list/watch/create/update/patch/delete;
  pods/pods/log/events/endpoints → get/list/watch; secrets → get/list/watch
  (ESO writes secrets; deployer never writes them).
- `networking.k8s.io`: networkpolicies → full CRUD.
- `networking.istio.io`: destinationrules/virtualservices and `security.istio.io`:
  authorizationpolicies → full CRUD only in `dx03v2` (full mesh exercise; inert
  without Istio CRDs).
- `gateway.networking.k8s.io`: gateways/httproutes → full CRUD.
- `networking.gke.io`: healthcheckpolicies/gcpbackendpolicies → full CRUD;
  `gcp-waf` writes and `gcp` deletes GCPBackendPolicies, so both are always required.
- `autoscaling`: horizontalpodautoscalers → full CRUD;
  `policy`: poddisruptionbudgets → full CRUD.
- `external-secrets.io`: externalsecrets → full CRUD.

GatewayClasses are cluster-scoped, outside this Role. Deploy checks the class
when readable; otherwise Gateway `Programmed` is the proof.

`deploy-gcp` accepts `platform_profile=core|full` and `deploy_mode=auto|gitops|push`.
`auto` chooses GitOps when Application `dx03v2` exists, direct apply otherwise;
permission/connection errors fail closed. With GitOps (`tx03v2` full, Argo CD owns
app manifests), deployment configures path, images and actual address/ranges/
Cloud SQL endpoint/hostname/Certificate Map in Application `dx03v2`
`spec.source.kustomize`, namespace `argocd`. It then publishes the app commit and
example-derived `params.env` to `gitops/gcp` and requests refresh. The parent
ignores only `spec.source.path`/`spec.source.kustomize` on that Application and
uses `RespectIgnoreDifferences=true`. `push` (no Argo CD or local script
`DEPLOY_MODE=push`) applies the overlay directly. The public branch receives no
real account/project IDs.

For full, the workflow runs from `main`, promotes verified digests to Artifact
Registry without rebuilding, attests each promoted digest (predicate
`https://github.com/maringelix/tx00v2/attestations/promoted-image/v1`, keyless
identity `deploy-gcp.yml` on `main`), verifies with `gh attestation verify`, then
deploys. TX Kyverno `ImageValidatingPolicy` requires that app signature. Managed
Google proxies have a separate narrow Gatekeeper exception; they are outside
the app repository's signature scope.

## GitHub Workload Identity Federation

Pool `tx03v2-github`, provider `github`, issuer
`https://token.actions.githubusercontent.com`, restricted to the owner and both
repositories. `dx03v2-gha-deploy` has `roles/iam.workloadIdentityUser` only for
exact subject `repo:<owner>@<owner id>/dx03v2@<repository id>:environment:lab`.
This immutable GitHub `sub` uses TX inputs `github_owner`, `github_owner_id` and
`dx03v2_repository_id`, with no defaults. A deleted/re-registered account has
different IDs and cannot inherit the lab. Environment `lab` deploys only from
`main`, so `deploy-gcp.yml` uses `environment: lab` (`policy-workflows` requires
it). GitHub variable `GCP_WORKLOAD_IDENTITY_PROVIDER` contains
`projects/<number>/locations/global/workloadIdentityPools/tx03v2-github/providers/github`.

TX lab grants `dx03v2-gha-deploy` `roles/artifactregistry.writer` on repository
`dx03v2`, `roles/container.clusterViewer` on the project (cluster credentials/DNS
endpoint), and `roles/parametermanager.parameterAccessor` on the project (contract).
No Secret Manager access. Promotion attestations use the same registry writer,
no new role. Kubernetes access comes only from the RoleBinding above. Laptop
`app_deployer_members` (`user:<email>` or `serviceAccount:<email>`, `group:` rejected)
get the same three roles and RoleBinding membership.

## Contract parameter: Parameter Manager `tx03v2-lab-contract`

Global `JSON` parameter read through alias `latest`:
`gcloud parametermanager parameters versions render latest --parameter=tx03v2-lab-contract
--location=global --project=<GCP_PROJECT_ID>`. Values are not secrets, but deploy
masks the project/service-account email in Actions. JSON contains exactly these
18 string-valued keys; extra, missing or empty values are rejected:

| Key | Value | dx03v2 use |
| --- | --- | --- |
| `project-id` | lab project ID | must equal `GCP_PROJECT_ID` |
| `region` | region | format checked; `get-credentials --location`, registry host, Cloud SQL CA bundle |
| `cluster-name` | `tx03v2-lab` | fixed value checked; `get-credentials --dns-endpoint` |
| `network-name` | `tx03v2-lab` | fixed value checked |
| `nodes-subnet-cidr` | node subnet CIDR | RFC1918 checked; must contain `db/endpoint-ip` |
| `db/endpoint-ip` | internal Cloud SQL PSC endpoint IP | `api-egress-to-cloudsql`: `<ip>/32`, port 5432 (`DB_ENDPOINT_IP`) |
| `lb-source-ranges` | fixed `35.191.0.0/16,130.211.0.0/22` | `web-ingress-from-lb`/`api-ingress-from-lb`, one ipBlock/range (`LB_SOURCE_RANGES`) |
| `artifact-registry/repository` | `<region>-docker.pkg.dev/<project_id>/dx03v2` | checked against region/project; `api`/`web` images (`API_IMAGE`, `WEB_IMAGE`) |
| `db/secret-name` | `tx03v2-lab-db-app` | checked against ExternalSecret `db-credentials` |
| `app/admin-token-secret-name` | `tx03v2-lab-app-admin-token` | checked against ExternalSecret `app-secrets` |
| `eso/cluster-secret-store` | `gcp-secret-manager` | checked against ExternalSecret `secretStoreRef` |
| `gateway/address-name` | `tx03v2-lab-gateway` | Gateway `spec.addresses`, `type: NamedAddress` (`GATEWAY_ADDRESS_NAME`) |
| `gateway/address` | reserved IPv4 | format checked; programmed Gateway must match; core smoke URL |
| `dns/hostname` | public app subdomain or `disabled` | `DNS_HOSTNAME`, required in full; Gateway listeners, HTTPS/redirect routes, full smoke URL |
| `dns/certificate-map` | Certificate Map name `tx03v2-lab-app` or `disabled` | `CERT_MAP`, Gateway `networking.gke.io/certmap`; disabled iff hostname disabled |
| `mesh/management` | `managed` or `disabled` | full requires managed Cloud Service Mesh, sidecars only in `dx03v2` |
| `waf/security-policy` | `tx03v2-lab-waf`, or `none` when TX `enable_waf=false` | GCPBackendPolicies `api`/`web`, `WAF_SECURITY_POLICY`, `gcp-waf`; none selects `gcp` and deletes old policies |
| `deploy/service-account` | `dx03v2-gha-deploy` email | must equal `dx03v2-gha-deploy@<GCP_PROJECT_ID>.iam.gserviceaccount.com` |

## Secret Manager (owned by tx03v2; deploy does not read it)

- `tx03v2-lab-db-app`: JSON string values `username`, `password`, `host`, `port`,
  `dbname`; `host` is the PSC instance DNS name
  (`<uid>.<project label>.<region>.sql.goog`) checked by `verify-full`.
- `tx03v2-lab-app-admin-token`: plain string, 48 random alphanumeric characters.
- Only ESO ServiceAccount `external-secrets/external-secrets`, a GKE WIF principal,
  has `roles/secretmanager.secretAccessor` on these secrets. Protected apply has
  separately scoped access for continuity synchronization; deploy/plan do not.

## Platform (installed by tx03v2 `platform/install.sh`)

- External Secrets Operator 2.12.0 in `external-secrets`; ClusterSecretStore
  `gcp-secret-manager`, provider `gcpsm`, no `auth` block, usable only from `dx03v2`.
- Namespace and Role/RoleBinding above. Google-managed Gateway controller,
  GatewayClass `gke-l7-global-external-managed`, Gateway API v1.5.0
  (GKE >=1.35.2-gke.1842000). GKE metrics-server serves API HPA.
- TX `platform/uninstall.sh` removes `dx03v2` before destroy and waits for Gateway
  finalizers and NEGs. The load balancer created by this repo's Gateway is outside
  Terraform state.

## Application runtime (dx03v2)

- Secret `db-credentials`: `DB_HOST`, `DB_PORT`, `DB_NAME`, `DB_USER`, `DB_PASSWORD`.
  Cloud ExternalSecret maps each `tx03v2-lab-db-app` JSON property; kind/Compose
  generate random values at runtime with `scripts/e2e-kind.sh`/`scripts/dev-env.sh`.
- Secret `app-secrets`, key `ADMIN_TOKEN`, from cloud ExternalSecret
  `tx03v2-lab-app-admin-token`.
- Cloud database TLS: `DB_SSL_MODE=verify-full`,
  `DB_SSL_CA_FILE=/etc/cloudsql-ca/ca.pem`, ConfigMap `cloudsql-ca` built from
  `https://storage.googleapis.com/cloudsql-ca-bundles/<region>.pem`. Deploy
  **rejects** non-certificate PEM blocks, absence of exactly one self-signed root
  with the SHA256 below, or a non-CA/certificate not issued by it (`openssl verify
  -x509_strict`, only this root, no system trust). openssl rewrites certificates
  into the ConfigMap. The bundle is never pinned because regional subordinate
  CAs rotate.

  | Root | SHA-256 (contract) | SHA-1 | Expiry |
  | --- | --- | --- | --- |
  | `CN=Google Cloud SQL Root Server CA 0b29df` (ECDSA P-384) | `C7B0FCD282B346F1FCC45EE8A79ECF6EF6FAEF2D669BEEC664293B93D83E59BE` | `9E0DDEC1969957360315A0B849CD609E6FC0905C` | 2049-06-27 |

  Local: `DB_SSL_MODE=disable`. `APP_ENV=lab` rejects anything except `verify-full`.
- `TRUST_PROXY_HOPS=2`: global external Application Load Balancer appends
  `<client IP>,<load balancer IP>` to `X-Forwarded-For`; connection comes from a
  Google Front End (`rate-limit` integration test).
- Services: `api` HTTP 3000, metrics 9464; `web` 8080.
- Cloud traffic: Gateway `dx03v2`, class `gke-l7-global-external-managed`,
  NamedAddress `gateway/address-name`. Core listens only HTTP 80. Full serves
  HTTPS 443 for `dns/hostname` using `dns/certificate-map` annotation
  `networking.gke.io/certmap` (no listener `tls` block/Secret). HTTP only sends a
  same-host/path 301 via `dx03v2-http-redirect`. HTTPRoute `dx03v2`: `/api` →
  `api:3000`, `/` → `web:8080`; HealthCheckPolicies web `/healthz`:8080 and API
  `/readyz`:3000; GCPBackendPolicies use `waf/security-policy`, omitted with `none`.
- TX Cloud Armor: preconfigured `sqli-v33-stable`/`xss-v33-stable` in `deny(403)`,
  inspect first 64 KB without size blocking, so API itself returns 413 for the
  70 KB smoke body. Rules must not block smoke; any rate limit must permit
  >=300 requests/minute/client.
- Cloud NetworkPolicies: web:8080/API:3000 ingress only from `lb-source-ranges`;
  API egress to `db/endpoint-ip`/32:5432; base DNS plus node cache
  `169.254.20.10/32:53` (Autopilot NodeLocal DNSCache). Full additionally allows
  pod egress to public 443 for managed control plane/Mesh CA and metadata server
  `169.254.169.254:80` (private ranges remain closed), Collector synthetic-probe
  ingress only to web:8080/API:3000, and mesh exercise traffic among
  `mesh-probe`, `mesh-intruder`, `mesh-stable`, `mesh-canary` only on 3000.
- Full mesh (`components/mesh-csm`): managed Cloud Service Mesh injects only in
  `dx03v2`, with namespace-default mTLS STRICT/identity authorization (trust domain
  `<project>.svc.id.goog`, principals `*/ns/dx03v2/sa/<account>`). Both backends
  use API image; VirtualService splits `/variant` 80/20, permits at most two
  `/fail` retries (`5xx`, 1 s/try), DestinationRule ejects after three consecutive
  5xx and AuthorizationPolicy permits only `mesh-probe` (`mesh-intruder`:403).
  Workload policies explicitly set PERMISSIVE on web8080 and API3000/9464 for
  load-balancer, monitoring and health traffic; AuthorizationPolicy/NetworkPolicy
  restrict these exceptions. Other ports inherit STRICT. Each pod requests a
  small proxy (`sidecar.istio.io/proxyCPU: 50m`, memory
  96 MiB, limit192 MiB). API excludes the Cloud SQL endpoint with
  `traffic.sidecar.istio.io/excludeOutboundIPRanges` because migration connects
  before sidecar startup and the database is outside mesh.
- Cloud SQL PostgreSQL 17 Enterprise, port5432, PSC only,
  `ssl_mode=ENCRYPTED_ONLY`, `server_ca_mode=GOOGLE_MANAGED_CAS_CA`.

## Local lab (tx03v2 local contract, version 2)

`scripts/deploy-local.sh` (`docs/LOCAL_LAB.md`) reads TX ConfigMap
`lab-system/lab-contract`, requires version `2` and rejects values differing from
the `local-platform` overlay: `registry=registry.tx03v2.local`,
`db.secret-name=tx03v2-lab-db-app`,
`app.admin-token-secret-name=tx03v2-lab-app-admin-token` (key `token`, versus plain
Secret Manager string), `eso.cluster-secret-store=local-secrets`,
`gateway.class=istio`, `tls.cluster-issuer=lab-ca`, `argocd.project=dx03v2`,
`monitoring.prometheus-service-account=monitoring/kube-prometheus-stack-prometheus`,
`tracing.otlp-endpoint=http://opentelemetry-collector.monitoring.svc:4318`
(version2 API endpoint/egress policies). It also reads `registry-push=localhost:5003`,
`network-cidr=10.252.0.0/24`, `db.endpoint-ip=10.252.0.11`, `db.ca-configmap`,
`gitops.push-url`, `gitops.read-url` and `gitops.push-key-secret`. Only AppProject
`dx03v2` allowed kinds enter the overlay (`contract-app`). Edge differences:
local Gateway preserves external `X-Request-Id` (`SMOKE_EDGE=istio`) and trusts
one hop (`TRUST_PROXY_HOPS=1`), versus two behind Google's load balancer. TX
`docs/CONTRACT.md` is authoritative.

## Changing the contract

1. Open cross-linked PRs in both repositories; increment the version in both
   `docs/CONTRACT.md` titles.
2. Update checks covering the item: `scripts/check-manifests.mjs`,
   `scripts/deploy-gcp.sh` (`CONTRACT_KEYS`, fixed values), `scripts/lib/k8s.sh`,
   and harness `CONTRACT_PARAMETER_KEYS`.
3. Merge the publisher (TX) before the consumer (DX), except removals, which
   require the reverse order.
