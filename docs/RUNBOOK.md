# dx03v2 runbook

Develop/test locally with npm, Compose and kind, then publish the approved app to
tx03v2 GKE Autopilot. Local execution is free and verified locally; Google Cloud
v2 remains `not run in the cloud (v2)`. Follow the
[central getting started guide](https://github.com/maringelix/tx00v2/blob/main/docs/GETTING_STARTED.md)
and TX RUNBOOK before the optional managed-service run.

## 1. Local prerequisites

- Docker/devcontainer with Docker-in-Docker, or Linux/WSL2 with Docker, bash>=4.4,
  Node.js24 (.nvmrc), curl, unzip, xz, Git and make.
- make tools installs pinned Trivy, hadolint, actionlint, shellcheck, kubeconform,
  Gitleaks, kind, kubectl and promtool in .tools.
- Ports: Compose8080 (WEB_PORT, loopback), development PostgreSQL15432 and
  Vite5173 (loopback), development API3000/metrics9464 (all interfaces).

## 2. npm workspace development

One root package-lock.json, workspaces api/web:

```bash
npm ci
# Disposable PostgreSQL17 and random credentials for this shell session.
export DB_PASSWORD="$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
export ADMIN_TOKEN="$(od -An -N24 -tx1 /dev/urandom | tr -d ' \n')"
docker run -d --rm --name dx03v2-dev-pg -p 127.0.0.1:15432:5432 \
  -e POSTGRES_DB=dx03v2 -e POSTGRES_USER=dx03v2 -e POSTGRES_PASSWORD="$DB_PASSWORD" \
  postgres:17-alpine@sha256:b0f9560a2de083e2cc7382e75f808c7381a32852a7ec49117deedb300e552b24
export DB_HOST=127.0.0.1 DB_PORT=15432 DB_NAME=dx03v2 DB_USER=dx03v2
node api/src/migrate.ts            # Node24 directly executes TypeScript
npm run dev --workspace api        # API3000,metrics9464,reload on save
npm run dev --workspace web        # another terminal,Vite5173,/api→3000
docker rm -f dx03v2-dev-pg         # when finished
```

Useful commands: npm run lint/typecheck/format/build. Web tests use
`npm run test:coverage --workspace web`. API integration tests **drop/recreate
tables** and require a database ending `_test`; all other names are rejected:

```bash
docker exec dx03v2-dev-pg createdb -U dx03v2 dx03v2_test
DB_NAME=dx03v2_test npm run test:coverage --workspace api
```

Full gate: HARNESS_STRICT=1 make verify. Without DB_HOST it creates a disposable
PostgreSQL; exported DB variables select that database and require _test.
Use `env -u DB_HOST HARNESS_STRICT=1 make verify` to ignore the development host.

## 3. Compose stack (project dx03v2-dev)

```bash
scripts/dev-env.sh                                  # random .env,mode600
docker compose -p dx03v2-dev up -d --build --wait   # db→migrate→api→web
scripts/compose-smoke.sh                            # smoke on localhost8080
docker compose -p dx03v2-dev down -v                # containers,network,DBvolume
```

- Only web is published, 127.0.0.1:${WEB_PORT:-8080}; API/database use internal networks.
- Read-only roots, cap_drop ALL, no-new-privileges.
- Admin UI accepts .env ADMIN_TOKEN, kept only in tab memory.
- Rotate with dev-env.sh --force then down -v; old volume retains its old password.
- Alternate port: WEB_PORT=18080 scripts/dev-env.sh --force.

## 4. kind end to end (make e2e)

```bash
make tools
make e2e
KEEP_CLUSTER=1 make e2e
kind get kubeconfig --name dx03v2-e2e > /tmp/dx03v2-e2e.kubeconfig
KUBECONFIG=/tmp/dx03v2-e2e.kubeconfig kubectl -n dx03v2 get pods,svc,networkpolicy
kind delete cluster --name dx03v2-e2e
```

e2e-kind.sh builds dx03v2-api:e2e/web:e2e, creates the pinned kind1.36.4 cluster,
loads images, generates random Secrets, applies local overlay, waits rollouts, proves
restricted admission rejects a privileged pod, runs nginx smoke through svc/web
port-forward and allowed/blocked NetworkPolicy probes. CI instead loads the exact
images artifact already scanned. Failure diagnostics:
$TMPDIR/dx03v2-harness/e2e-diagnostics.

## 5. Google Cloud prerequisites

> Historical core estimates (2026-10-11, us-central1):USD0.12/hour with available
> GKE credit, USD0.22 without; Gateway LB ~USD0.025/hour plus data, Cloud Armor
> ~USD0.011/hour. These are not invoices. Read updated TX COSTS/FINOPS for full,
> HA/DR, mandatory regional estimate/budget/expiry and same-day destroy.

1. TX bootstrap/apply/platform complete:contract, reserved address, registry, ESO/
   gcp-secret-manager, dx03v2 namespace/deployer Role/Binding. Laptop operators
   need app_deployer_members IAM plus a subsequent platform RoleBinding refresh.
   Full additionally requires managed mesh ACTIVE and delegated DNS/certificate
   ACTIVE; read TX prerequisites before selecting full here.
2. Repository guardrails/protected lab/main, with immutable subject
   `repo:<owner>@<owner id>/dx03v2@<repository id>:environment:lab`.
3. Variables below. No Google service-account JSON key.
4. Laptop:authenticated gcloud/auth plugin, pinned kubectl, Node24, Git, curl, base64,
   openssl, awk, gh, jq, crane and a verified release bundle. See deploy-gcp.sh header.
   Use a dedicated CLOUDSDK_CONFIG directory to preserve other projects' logins.

## 6. GitHub variables and IAM

Settings > Secrets and variables > Actions > Variables. Public logs expose them;
store no private credentials. Initial Check repository variables validates all
three against bootstrap github_variables_dx03v2:

| Variable | Example | Use |
|---|---|---|
| GCP_PROJECT_ID |tx03v2-lab-example|must equal contract project-id|
| GCP_WORKLOAD_IDENTITY_PROVIDER |projects/000000000000/locations/global/workloadIdentityPools/tx03v2-github/providers/github|WIF provider|
| GCP_DEPLOY_SERVICE_ACCOUNT |dx03v2-gha-deploy@tx03v2-lab-example.iam.gserviceaccount.com|must be the deploy identity in this project|

TX grants deploy identity/laptop members registry writer only on dx03v2,
project clusterViewer/parameterAccessor, and dx03v2-deployers RoleBinding. No
Secret Manager grant. Operators belong in TX secret LAB_APP_DEPLOYER_MEMBERS,
not a public variable. CONTRACT defines exact scopes.

## 7. Deploy

Only a CI-approved release from current main is accepted. Deployment never rebuilds.

1. Run publish-images from main with successful source ci_run_id for current
   main commit. Release verification requires six successful source jobs:
   static, test, images, e2e, e2e-platform, continuity. The small job also runs CI but
   is not enumerated by the release verifier. The publisher checks image IDs,
   SBOMs/attestations and publishes approved bytes to GHCR.
2. Run deploy-gcp from main with that successful publication release_run_id.
   Select target=primary|secondary, installed platform_profile=core|full and
   deploy_mode=auto|gitops|push. Auto detects Application dx03v2; permission or
   connection failures stop deployment rather than being treated as absence.
   verify-release checks source jobs, hashes/attestations before lab approval.
3. After approval, validate variables, download/verify again, authenticate WIF and
   install kubectl/crane/gcloud.
4. deploy-gcp.sh --promote-only copies exact verified GHCR digests to Artifact
   Registry with crane. actions/attest signs each destination with predicate
   https://github.com/maringelix/tx00v2/attestations/promoted-image/v1;gh attestation
   verify checks fork deploy-gcp.yml/main, GitHub issuer and job commit. Promotion
   must preserve digest and image configuration ID.
5. Script runs again:reads18keys, checks digests/image IDs, writes GitOps revision
   or directly applies, waits Argo/ESO/rollouts/programmed contract Gateway/smoke.
   Full uses gcp-full or gcp-waf-full, verified hostname HTTPS/HTTP301, and requires
   istio-proxy in every API/web pod after rollout.

Full needs TX managed mesh, Kyverno policy, domain/certificate and main workflow
promotion signature. Release verification itself makes no cloud changes; only
protected deploy does. Google Cloud v2 remains unrun.

Laptop DEPLOY_MODE=push still requires RELEASE_DIR, RELEASE_RUN_ID, GH_TOKEN,
GITHUB_REPOSITORY, GITHUB_ACTOR and own cloud credentials. Full accepts only
digests already carrying the main-workflow promotion signature; manual execution
cannot create that identity. Use the two workflows for normal delivery.

For recovery, follow CONTINUITY:secondary selects tx03v2-lab-dr-contract and
gitops/gcp-dr only after authorized fencing/promotion. A deploy does not promote
DB or switch DNS. Test secondary reserved address with the TLS hostname before
TX LAB_ACTIVE_REGION changes DNS.

### Mesh exercise (full)

After deployment, run two disposable dx03v2 pods as mesh-probe (allowed) and
mesh-intruder (denied), using the API image from
`kubectl -n dx03v2 get deployment mesh-stable -o jsonpath='{.spec.template.spec.containers[0].image}'`.
Set app.kubernetes.io/name to their respective names, args dist/mesh-probe.js,
MESH_PROBE_MODE=allowed/intruder; target defaults http://mesh-demo:3000. Sidecars
keep the pod alive, so read logs for MESH_PROBE_RESULT or
MESH_PROBE_DENIED status=403 then delete it. CI proves the same exercise locally
in ambient with make e2e-platform/mesh; the managed cloud exercise is unrun.

If full pods are initially unready, inspect istio-proxy logs. mesh-sidecar-egress
allows public443 and metadata server; exact managed control-plane/MeshCA addresses
need confirmation during the first run. After observation, review/narrow the rule;
it is the namespace's only external443 rule.

## 8. Verify

Primary/core examples (use secondary contract/region when selected):

```bash
export KUBECONFIG=/tmp/dx03v2-lab.kubeconfig
gcloud container clusters get-credentials tx03v2-lab --location us-central1 \
  --project "$GCP_PROJECT_ID" --dns-endpoint
kubectl -n dx03v2 get pods,gateway,httproute,externalsecrets,hpa
kubectl -n dx03v2 get healthcheckpolicies.networking.gke.io,gcpbackendpolicies.networking.gke.io
curl -fsS "http://$(kubectl -n dx03v2 get gateway dx03v2 -o jsonpath='{.status.addresses[0].value}')/api/info"
```

Full must use HTTPS hostname and validate redirect; SQL-injection WAF probe should
receive403 (TX RUNBOOK). Cloud Trace Explorer should show dx03v2-api:
API→observability Collector OTLP/HTTP4318→Cloud Trace. TX owns Collector and
cloudtrace.agent. Record actual results rather than assuming local equivalence.

## 9. Shut down

TX destroy/uninstall removes appnamespace, waits Gatewayfinalizer/NEGs, then removes
IaC resources. This prevents LB leaks outside Terraform state. Review full/DR
backup retention, DB protection and both runtimes using TX RUNBOOK/CONTINUITY.
To remove only ingress while retaining cluster, delete Gateway dx03v2; the TX
reserved address remains and bills while unattached. With Argo enabled, pause or
change desired configuration deliberately so reconciliation does not recreate it.

## 10. Troubleshooting

| Symptom | Likely cause | Action |
|---|---|---|
| Repository variable problem | absent/wrong format | section 6 |
| Dirty tree/GIT_SHA not checked-out commit | source differs from approved commit | commit/stash, checkout intended release SHA |
| No active gcloud credential | laptop login/auth step absent | login/check workflow vars |
| Cannot render contract | unapplied TX/wrong project/no parameterAccessor | apply/correct project/grants |
| Contract keys/value mismatch | TX/DX interface versions differ | compare both CONTRACT files, coordinated PRs |
| project-id differs | parameter from another project | correct GCP_PROJECT_ID |
| Cannot get cluster credentials | missing clusterViewer/cluster | section 6/TX apply |
| Cluster does not serve API | platform absent/ESO or Gateway API missing | TX platform |
| Cannot deploy namespace | missing User binding/Role verb | TX platform/members; policy plurals healthcheckpolicies, gcpbackendpolicies |
| Registry auth/promotion rejected | writer missing, GHCR token lacks packages:read, invalid release | scoped roles/bundle verification |
| CA bundle refused | wrong/multiple root or foreign certificate | stop/check official CAs; root change requires contract |
| ExternalSecret notReady | store/ESOidentity/secret missing | describe db-credentials, TX platform |
| Migration TLS error | cloudsql-ca missing/secret host not instance DNS | script recreates CA; check secret host/privateDNS |
| Gateway notProgrammed15min | class/address/Armor policy missing | describe Gateway/controller events |
| Gateway at wrong address | reservation changed after contract | reapply TX/contract |
| Smoke502/timeout afterProgrammed | propagation/health checks | wait, describe policies/check LB NetworkPolicy ranges |
| Smoke403 everywhere | Cloud Armor rule | inspect Armor logs; contract must permit smoke |
| ImagePullBackOff | node identity lacks registry read | verify TX apply/grant |
| No Cloud Trace | old platform/no Collector/no cloudtrace.agent | observability pods/logs; API does not fail, spans are lost |

## 11. Record evidence

Cloud run report includes date, region, TX/DX commits, GKE version, steps, duration,
actual cost, smoke output, issues and redacted TX leftovers. Never publish secret
values, real IDs, state or planJSON.
