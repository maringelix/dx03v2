# Migrations with expand and contract

The API and PostgreSQL schema are released separately. An application rollback does not roll the
database back. Migrations run once from the same image as the API, under a PostgreSQL advisory lock;
each file has a checksum and runs in its own transaction.

## Release sequence

1. **Expand:** add an optional field or table that the current release can ignore. The R7.2 exercise
   adds nullable messages.display_name. Inserts and reads from the previous image still work.
2. **Deploy compatible code:** the new release may dual-read or dual-write the expanded schema. Keep
   the previous image available through the rollback window. A failed migration rolls back its
   transaction; the integration test proves the partial table creation is absent.
3. **Backfill and observe:** run a bounded, resumable backfill if the feature needs one. Track
   progress and errors; do not put an unbounded table rewrite in the deployment init container.
4. **Contract later:** only after every old replica and the rollback window have ended, make the field
   required, switch reads, or remove the old field in a later release. Do not contract in the same
   release that first expands the schema.

The platform CI release drill starts with the previous image, applies the additive migration while
that image is serving, checks continuous reads during the new rollout, then forces an unavailable
image. It verifies the old replicas stay ready, GitOps restores the previous image, the pre-release
message remains, and the expanded database column remains. This is an application rollback, not a
database restore.

## When data recovery is needed

Application rollback is appropriate when code is faulty and the schema is still backward compatible.
It cannot restore deleted or overwritten rows. Use the database backup/PITR procedure for data loss,
record the restore point, and rehearse it separately. An irreversible migration needs a backup and a
tested forward-fix or restore plan before release; never assume switching the image reverses it.

Run the database integration checks with make test. Run the end-to-end platform exercise with
make e2e-platform; CI runs that heavy check against the disposable local platform and never a cloud.
