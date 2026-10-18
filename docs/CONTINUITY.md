# R9 — data, regional loss and failback

Status: implemented; the `continuity` job publishes measurements for each commit.
Nothing of v2 has run in GCP. A Docker result does not certify an SLA, latency,
managed replication or Cloud SQL promotion.

## Reproducible experiment without a cloud account

`make continuity` requires the two images already built by CI. This is a heavy
experiment intended for Actions. It does not build a different image from the
one approved by the scanners.

1. Create A and B with independent backend/frontend networks and disks; neither
   database exposes a host port. Only the application publishes HTTP on loopback
   using a random port.
2. Recover a configuration package and ephemeral secrets by checksum. Verify image
   IDs; the package and private keys never enter artifacts.
3. Use PostgreSQL with TLS `verify-full`, an ephemeral CA and SAN `db`. The API
   mounts only the public CA. The database and frontend do not share a direct network.
4. Write a marker through the API behind nginx, stop the database and prove reads
   fail. Restart the database and require recovery through the same API, without
   restarting it.
5. Run `pg_dump -Fc`, verify its catalog and SHA256, write a later transaction and
   require promotion to be refused while the primary is alive.
6. Corrupt a backup copy and require rejection before any restore.
7. Stop every writer in A, verify fencing and destroy its disk. Restore B from
   the intact backup and start the same application version.
8. Require the earlier marker and the absence of the transaction written after
   the backup. Measure RPO from the start of the consistent backup to failure;
   RTO runs from failure until application B serves and confirms the data.
   Local limits: 120 s/180 s.
9. Write in B, produce a new backup, fence B and rebuild A on a new disk. Failback
   must preserve both original data and writes made in B within 180 s. B must
   remain unable to write.

`continuity/continuity.json` records checksums, image IDs, RPO, RTO, failback time
and the intentional loss of one transaction. Errors fail the job. Cleanup checks
the exclusive run label before removing each resource. It does not use another
task's volume, network, Kubernetes context or Compose project.

## What each layer recovers

| Layer | Mechanism | Evidence |
|---|---|---|
| API reconnection | pool discards a broken connection and opens another | database interruption with the same API container |
| Logical application backup | `pg_dump`, catalog and SHA256 | marker preserved and corruption rejected |
| Physical archive/WAL and PITR | `tx03v2` exercise | verified base backup, restore point, deleted transaction recovered |
| Kubernetes PVC | Velero in `tx03v2` | restore verifies checksums after removing the original PVC |
| Environment loss and failback | independent A/B networks and disks | `continuity` job, fencing and new data preserved |
| Images and supply chain | artifact from the `images` job itself, signed deploy release | same IDs in A and B, R7 gates |
| Managed database and runtime | `dr` profile and `tx03v2` runbook | Terraform mocks/validation; not run in the cloud |

In the cloud, confirm the plan and contract region before changing anything.
Block GitOps/deploys and old writers before promoting the replica; DNS changes
alone do not prevent split brain. Follow the pair's runbook, watch replication
lag, retain RPO/RTO evidence and perform failback only after consistently reseeding
the original region. If the original region cannot be isolated, stop promotion
and escalate to the operator.

Do not copy the local `.env` file into the cloud. Regional secrets belong in
Secret Manager and regional workload identities. Promotion publishes the already
signed digests in the recovered region's registry; it must not rebuild the code.

## Deploying the managed recovery environment

With the TX `dr` profile applied and the database promoted **after fencing**,
install the secondary platform with `LAB_TARGET=secondary`. In `deploy-gcp`,
select `target=secondary`, the same signed release and the installed platform
profile. The script reads `tx03v2-lab-dr-contract`, obtains the kubeconfig for
`tx03v2-lab-dr`, promotes digests into the regional registry and publishes
`gitops/gcp-dr`. The `region-target` test rejects arbitrary cluster/contract references.

First verify the secondary's reserved address with local resolution of the TLS
hostname. Only after reads, a proof write and data acceptance should you set
`LAB_ACTIVE_REGION=secondary` in TX and review/apply the DNS plan. This input
requires `dr`; it does not fence or promote anything by itself. Record the last
accepted primary write, replica lag and first accepted secondary write to measure
cloud RPO/RTO.

Publication/deploy CI also requires `continuity` to pass at the release source.
For failback, rebuild the original region from the promoted database, synchronize,
freeze writes, fence the secondary and only then return DNS and the primary
deployment branch. Do not reapply a promoted Terraform replica without reconciling
its state and reviewing the plan; doing so can cause replacement or data loss.
