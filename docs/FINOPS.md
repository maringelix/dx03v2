# R10 — application capacity, SLO and rightsizing

Built for forks; nothing of GCP v2 has run in the cloud.
The complete workflow uses the tx03v2 revision pinned in `deploy/local/tx03v2.ref`.
The small scenario remains one node/7 GiB; the capacity scenario uses
`LOCAL_TOPOLOGY=ha`, `LOCAL_FINOPS=1` and recommends 12 GiB available to Docker.
Heavy runs belong in Actions.

## Lesson and evidence

CI `e2e-platform` runs `scripts/capacity-app.sh` after the preceding probes.
On Linux/a devcontainer with enough resources:

    LOCAL_TOPOLOGY=ha LOCAL_FINOPS=1 make e2e-platform

The test accepts only the `kind-tx03v2-local` kubeconfig. It measures real HTTPS
requests to `/api/messages` through the Gateway with a verified CA, without
recording or exposing credentials. Every phase has bounded concurrency and
duration, a pod deadline and cleanup.

1. Measure a baseline with 4 clients for 30 seconds (success >=99%, p99 <=1.5 s).
2. Inject CPU StressChaos with 500m API CPU limits alongside the HTTP load.
   Require the HPA to reach four ready replicas.
3. Drain only API pods from a worker owned by kind. PDB, readiness and
   RollingUpdate remain active; the client must maintain the same SLO throughout.
4. Remove the stress, experiment with CPU requests of 100m → 50m and require
   scale-down to two replicas. Repeat the same load/SLO and record aggregate
   requests before and after.
5. Lock a PostgreSQL table for 10 s: require at least ten blocked API connections,
   a saturated pool and client-visible errors. After releasing the lock, require
   recovery and repeat the SLO. More pods do not fix a database bottleneck.
6. Require a VPA recommendation with `updateMode: Off`; a quota must reject an
   expensive pod for exceeding CPU. The evidence JSON contains counts/latency,
   without response bodies.

The Argo CD controller is paused during the imperative experiment. A trap restores
requests, HPA and the controller's original replica count, including on failure.
GitOps manifests remain the source of permanent configuration. The normal HPA
uses stabilization windows; only this test uses a short scale-down window.

## Showback and interpretation

Every application pod template requires `cost.lab/owner` and `cost.lab/environment`;
the `contract-app` check fails if either label is missing. Adjust the owner in
kustomize to identify the person responsible for the lesson. tx03v2 installs
OpenCost and Grafana: see the [infrastructure FinOps lesson](https://github.com/maringelix/tx03v2/blob/main/docs/FINOPS.md)
for `/allocation`, idle/shared costs, sources/date/currency/region and services
outside pods.

Reducing requests does not guarantee savings: the HPA may request more replicas.
Compare aggregate requests, measured usage, latency, errors and allocation under
the same load. The 50m candidate is an experiment, restored on exit; it does not
automatically change production configuration. VPA Off does not compete with the
HPA over requests.

## GCP and cleanup

Autopilot provisions capacity from requests; the tx03v2 Spot lesson uses a disposable
task with a deadline and an explicit on-demand fallback, preserving the critical
application. Increasing kind replicas does not prove managed scaling or GCP prices.
Use the tx03v2 estimate, budget and expiry gate before any apply; treat OpenCost as
allocation evidence and a budget as an alert, never as a billing cap.

On failure, inspect `capacity-app.json`, events, HPA/PDB/VPA, metrics-server,
the database pool/connections and Gateway logs. E2E teardown always destroys the
resources created by that state and checks for leftovers. Cloud cleanup uses the
pair's runbook and belongs only to the authorized cloud run.
